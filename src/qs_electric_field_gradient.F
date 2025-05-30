!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Calculates electric field gradients
!>      H.M. Petrili, P.E. Blochl, P. Blaha, K. Schwarz, PRB 57, 14690 (1998)
!> \par History
!>      12.2007 Added checksum for interpolation regtest [rdeclerck]
!> \author JGH (03-05-2006)
! **************************************************************************************************
MODULE qs_electric_field_gradient
   USE atomic_kind_types,               ONLY: atomic_kind_type,&
                                              get_atomic_kind
   USE basis_set_types,                 ONLY: get_gto_basis_set,&
                                              gto_basis_set_type
   USE cp_control_types,                ONLY: dft_control_type
   USE cp_log_handling,                 ONLY: cp_get_default_logger,&
                                              cp_logger_type
   USE cp_output_handling,              ONLY: cp_print_key_unit_nr
   USE eigenvalueproblems,              ONLY: diagonalise
   USE input_section_types,             ONLY: section_get_lval,&
                                              section_vals_get_subs_vals,&
                                              section_vals_type,&
                                              section_vals_val_get
   USE kinds,                           ONLY: dp
   USE mathconstants,                   ONLY: fac,&
                                              fourpi
   USE message_passing,                 ONLY: mp_para_env_type
   USE orbital_pointers,                ONLY: indso,&
                                              nsoset
   USE particle_types,                  ONLY: particle_type
   USE paw_basis_types,                 ONLY: get_paw_basis_info
   USE physcon,                         ONLY: a_bohr,&
                                              e_charge,&
                                              joule
   USE pw_env_types,                    ONLY: pw_env_get,&
                                              pw_env_type
   USE pw_methods,                      ONLY: pw_dr2,&
                                              pw_integral_ab,&
                                              pw_smoothing,&
                                              pw_structure_factor,&
                                              pw_transfer
   USE pw_poisson_methods,              ONLY: pw_poisson_solve
   USE pw_poisson_types,                ONLY: pw_poisson_type
   USE pw_pool_types,                   ONLY: pw_pool_type
   USE pw_spline_utils,                 ONLY: &
        Eval_Interp_Spl3_pbc, Eval_d_Interp_Spl3_pbc, find_coeffs, pw_spline_do_precond, &
        pw_spline_precond_create, pw_spline_precond_release, pw_spline_precond_set_kind, &
        pw_spline_precond_type, spl3_pbc
   USE pw_types,                        ONLY: pw_c1d_gs_type,&
                                              pw_r3d_rs_type
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_environment_type
   USE qs_gapw_densities,               ONLY: prepare_gapw_den
   USE qs_harmonics_atom,               ONLY: get_none0_cg_list,&
                                              harmonics_atom_type
   USE qs_kind_types,                   ONLY: get_qs_kind,&
                                              qs_kind_type
   USE qs_ks_methods,                   ONLY: calc_rho_tot_gspace
   USE qs_rho_atom_types,               ONLY: rho_atom_type
   USE qs_rho_types,                    ONLY: qs_rho_type
   USE util,                            ONLY: get_limit,&
                                              sort
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE
   PUBLIC :: qs_efg_calc

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'qs_electric_field_gradient'

CONTAINS

! **************************************************************************************************
!> \brief ...
!> \param qs_env ...
! **************************************************************************************************
   SUBROUTINE qs_efg_calc(qs_env)

      TYPE(qs_environment_type), POINTER                 :: qs_env

      CHARACTER(LEN=*), PARAMETER                        :: routineN = 'qs_efg_calc'

      CHARACTER(LEN=2)                                   :: element_symbol
      INTEGER                                            :: aint_precond, handle, i, iat, iatom, ij, &
                                                            ikind, j, max_iter, natom, natomkind, &
                                                            nkind, nspins, precond_kind, unit_nr
      INTEGER, DIMENSION(:), POINTER                     :: atom_list
      LOGICAL                                            :: efg_debug, efg_interpolation, gapw, &
                                                            paw_atom, smoothing, success
      REAL(KIND=dp)                                      :: chk_spl, ecut, efg_units, efg_val, &
                                                            ehartree, eps_r, eps_x, f1, f2, sigma
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:, :)        :: efg_diagval, vh0
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:, :, :)     :: efg_pw, efg_tensor
      REAL(KIND=dp), DIMENSION(3)                        :: eigenvalues, ra
      REAL(KIND=dp), DIMENSION(3, 3)                     :: eigenvectors
      REAL(KIND=dp), DIMENSION(:), POINTER               :: rvals
      TYPE(atomic_kind_type), DIMENSION(:), POINTER      :: atomic_kind_set
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(mp_para_env_type), POINTER                    :: para_env
      TYPE(particle_type), DIMENSION(:), POINTER         :: particle_set
      TYPE(pw_c1d_gs_type)                               :: rho_tot_gspace, structure_factor, &
                                                            v_hartree_gspace
      TYPE(pw_c1d_gs_type), DIMENSION(6)                 :: dvr2
      TYPE(pw_env_type), POINTER                         :: pw_env
      TYPE(pw_poisson_type), POINTER                     :: poisson_env
      TYPE(pw_pool_type), POINTER                        :: auxbas_pw_pool
      TYPE(pw_r3d_rs_type)                               :: dvr2rs
      TYPE(pw_r3d_rs_type), DIMENSION(6)                 :: dvspl
      TYPE(pw_spline_precond_type)                       :: precond
      TYPE(qs_kind_type), DIMENSION(:), POINTER          :: qs_kind_set
      TYPE(qs_rho_type), POINTER                         :: rho
      TYPE(rho_atom_type), DIMENSION(:), POINTER         :: rho_atom_set
      TYPE(section_vals_type), POINTER                   :: dft_section, input, interp_section

      NULLIFY (atomic_kind_set, qs_kind_set, dft_control, para_env, particle_set, rho, &
               rho_atom_set, input, dft_section, interp_section)

      CALL timeset(routineN, handle)

      logger => cp_get_default_logger()

      chk_spl = 0.0_dp
      efg_units = Joule/a_bohr**2/e_charge*1.e-21_dp
      f1 = SQRT(15._dp/fourpi)
      f2 = SQRT(5._dp/fourpi)

      CALL get_qs_env(qs_env=qs_env, dft_control=dft_control, &
                      rho=rho, qs_kind_set=qs_kind_set, &
                      atomic_kind_set=atomic_kind_set, &
                      rho_atom_set=rho_atom_set, pw_env=pw_env, &
                      particle_set=particle_set, para_env=para_env, &
                      input=input)

      dft_section => section_vals_get_subs_vals(input, "DFT")

      efg_interpolation = section_get_lval(section_vals=dft_section, &
                                           keyword_name="PRINT%ELECTRIC_FIELD_GRADIENT%INTERPOLATION")
      efg_debug = section_get_lval(section_vals=dft_section, &
                                   keyword_name="PRINT%ELECTRIC_FIELD_GRADIENT%DEBUG")
      CALL section_vals_val_get(dft_section, &
                                "PRINT%ELECTRIC_FIELD_GRADIENT%GSPACE_SMOOTHING", &
                                r_vals=rvals)
      ecut = rvals(1)
      sigma = rvals(2)
      IF (ecut == 0._dp .AND. sigma <= 0._dp) THEN
         smoothing = .FALSE.
         ecut = 1.e10_dp ! not used, just to have vars defined
         sigma = 1._dp ! not used, just to have vars defined
      ELSEIF (ecut == -1._dp .AND. sigma == -1._dp) THEN
         smoothing = .TRUE.
         CALL pw_env_get(pw_env, auxbas_pw_pool=auxbas_pw_pool)
         CALL auxbas_pw_pool%create_pw(dvr2rs)
         ecut = 2._dp*dvr2rs%pw_grid%cutoff*0.875_dp
         sigma = 2._dp*dvr2rs%pw_grid%cutoff*0.125_dp
         CALL auxbas_pw_pool%give_back_pw(dvr2rs)
      ELSE
         smoothing = .TRUE.
      END IF
      CPASSERT(ecut > 0._dp)
      CPASSERT(sigma > 0._dp)

      unit_nr = cp_print_key_unit_nr(logger, dft_section, "PRINT%ELECTRIC_FIELD_GRADIENT", &
                                     extension=".efg", log_filename=.FALSE.)

      IF (unit_nr > 0) THEN
         WRITE (unit_nr, "(/,A,/)") " ELECTRIC FIELD GRADIENTS [10**21 V/m^2]"
         IF (efg_interpolation) THEN
            WRITE (unit_nr, "(T16,A)") &
               " Smooth potential contribution calculated by spline interpolation"
         ELSE
            WRITE (unit_nr, "(T12,A)") &
               " Smooth potential contribution calculated by plane wave interpolation"
         END IF
         IF (smoothing) THEN
            WRITE (unit_nr, "(T36,A)") &
               " G-Space potential smoothed by Fermi function"
            WRITE (unit_nr, "(T36,A,T71,F10.4)") " Cutoff (eV) ", ecut
            WRITE (unit_nr, "(T36,A,T71,F10.4)") " Width (eV) ", sigma
         END IF
         WRITE (unit_nr, *)
      END IF

      gapw = dft_control%qs_control%gapw
      nspins = dft_control%nspins

      natom = SIZE(particle_set, 1)
      ALLOCATE (efg_tensor(3, 3, natom))
      efg_tensor = 0._dp
      IF (efg_debug) THEN
         ALLOCATE (efg_pw(3, 3, natom))
         efg_pw = 0._dp
      END IF
      ALLOCATE (efg_diagval(3, natom))
      efg_diagval = 0._dp

      ALLOCATE (vh0(1:natom, -2:2))
      vh0 = 0._dp

      !prepare calculation
      CALL pw_env_get(pw_env, auxbas_pw_pool=auxbas_pw_pool, &
                      poisson_env=poisson_env)
      IF (gapw) CALL prepare_gapw_den(qs_env, do_rho0=.TRUE.)

      !calculate electrostatic potential
      CALL auxbas_pw_pool%create_pw(v_hartree_gspace)
      CALL auxbas_pw_pool%create_pw(rho_tot_gspace)
      CALL calc_rho_tot_gspace(rho_tot_gspace, qs_env, rho)

      CALL pw_poisson_solve(poisson_env, rho_tot_gspace, ehartree, &
                            v_hartree_gspace)
      CALL auxbas_pw_pool%give_back_pw(rho_tot_gspace)

      ! smoothing of potential
      IF (smoothing) CALL pw_smoothing(v_hartree_gspace, ecut, sigma)

      DO i = 1, 3
         DO j = 1, i
            ij = (i*(i - 1))/2 + j
            CALL auxbas_pw_pool%create_pw(dvr2(ij))
            CALL pw_dr2(v_hartree_gspace, dvr2(ij), i, j)
         END DO
      END DO

      IF (.NOT. efg_interpolation) THEN
         CALL auxbas_pw_pool%create_pw(structure_factor)
      ELSE

         interp_section => section_vals_get_subs_vals(dft_section, &
                                                      "PRINT%ELECTRIC_FIELD_GRADIENT%INTERPOLATOR")
         CALL section_vals_val_get(interp_section, "aint_precond", &
                                   i_val=aint_precond)
         CALL section_vals_val_get(interp_section, "precond", i_val=precond_kind)
         CALL section_vals_val_get(interp_section, "max_iter", i_val=max_iter)
         CALL section_vals_val_get(interp_section, "eps_r", r_val=eps_r)
         CALL section_vals_val_get(interp_section, "eps_x", r_val=eps_x)

         CALL auxbas_pw_pool%create_pw(dvr2rs)
         DO i = 1, 6
            CALL auxbas_pw_pool%create_pw(dvspl(i))
            CALL pw_transfer(dvr2(i), dvr2rs)
            ! calculate spline coefficients
            CALL pw_spline_precond_create(precond, precond_kind=aint_precond, &
                                          pool=auxbas_pw_pool, pbc=.TRUE., transpose=.FALSE.)
            CALL pw_spline_do_precond(precond, dvr2rs, dvspl(i))
            CALL pw_spline_precond_set_kind(precond, precond_kind)
            success = find_coeffs(values=dvr2rs, coeffs=dvspl(i), &
                                  linOp=spl3_pbc, preconditioner=precond, pool=auxbas_pw_pool, &
                                  eps_r=eps_r, eps_x=eps_x, max_iter=max_iter)
            CPASSERT(success)
            CALL pw_spline_precond_release(precond)
            CALL auxbas_pw_pool%give_back_pw(dvr2(i))
         END DO
         CALL auxbas_pw_pool%give_back_pw(dvr2rs)
      END IF

      nkind = SIZE(qs_kind_set)

      DO ikind = 1, nkind
         NULLIFY (atom_list)
         CALL get_atomic_kind(atomic_kind_set(ikind), atom_list=atom_list, natom=natomkind)
         CALL get_qs_kind(qs_kind_set(ikind), paw_atom=paw_atom)
         DO iat = 1, natomkind
            iatom = atom_list(iat)
            ra = particle_set(iatom)%r
            IF (efg_interpolation) THEN
               DO i = 1, 3
                  DO j = 1, i
                     ij = (i*(i - 1))/2 + j
                     efg_val = Eval_Interp_Spl3_pbc(ra, dvspl(ij))
                     efg_tensor(i, j, iatom) = -efg_val
                     efg_tensor(j, i, iatom) = efg_tensor(i, j, iatom)
                     IF (efg_debug) THEN
                        chk_spl = chk_spl + efg_val + &
                                  SUM(Eval_d_Interp_Spl3_pbc(ra, dvspl(ij)))
                     END IF
                  END DO
               END DO
            ELSE
               CALL pw_structure_factor(structure_factor, ra)
               DO i = 1, 3
                  DO j = 1, i
                     ij = (i*(i - 1))/2 + j
                     efg_tensor(i, j, iatom) = -pw_integral_ab(dvr2(ij), structure_factor)
                     efg_tensor(j, i, iatom) = efg_tensor(i, j, iatom)
                  END DO
               END DO
               efg_tensor(:, :, iatom) = efg_tensor(:, :, iatom)/structure_factor%pw_grid%vol
            END IF
            IF (efg_debug) THEN
               efg_pw(:, :, iatom) = efg_tensor(:, :, iatom)
            END IF
         END DO

         IF (paw_atom) THEN
            CALL vlimit_atom(para_env, vh0, rho_atom_set, qs_kind_set(ikind), &
                             atom_list, natomkind, nspins)
            DO iat = 1, natomkind
               iatom = atom_list(iat)
               efg_tensor(1, 1, iatom) = efg_tensor(1, 1, iatom) &
                                         + f1*(vh0(iatom, 2)) - f2*(vh0(iatom, 0))
               efg_tensor(2, 2, iatom) = efg_tensor(2, 2, iatom) &
                                         - f1*(vh0(iatom, 2)) - f2*(vh0(iatom, 0))
               efg_tensor(3, 3, iatom) = efg_tensor(3, 3, iatom) + 2._dp*f2*(vh0(iatom, 0))
               efg_tensor(1, 2, iatom) = efg_tensor(1, 2, iatom) + f1*(vh0(iatom, -2))
               efg_tensor(2, 1, iatom) = efg_tensor(2, 1, iatom) + f1*(vh0(iatom, -2))
               efg_tensor(1, 3, iatom) = efg_tensor(1, 3, iatom) + f1*(vh0(iatom, 1))
               efg_tensor(3, 1, iatom) = efg_tensor(3, 1, iatom) + f1*(vh0(iatom, 1))
               efg_tensor(2, 3, iatom) = efg_tensor(2, 3, iatom) + f1*(vh0(iatom, -1))
               efg_tensor(3, 2, iatom) = efg_tensor(3, 2, iatom) + f1*(vh0(iatom, -1))
            END DO
         END IF

         DO iat = 1, natomkind
            iatom = atom_list(iat)
            CALL diagonalise(efg_tensor(:, :, iatom), 3, "U", &
                             eigenvalues, eigenvectors)
            CALL efgsort(eigenvalues, efg_diagval(:, iatom))
         END DO
      END DO ! ikind

      efg_tensor(:, :, :) = efg_tensor(:, :, :)*efg_units
      efg_diagval(:, :) = efg_diagval(:, :)*efg_units

      IF (efg_debug) THEN
         efg_pw(:, :, :) = efg_pw(:, :, :)*efg_units
         DO iatom = 1, natom
            IF (unit_nr > 0) THEN
               CALL get_atomic_kind(particle_set(iatom)%atomic_kind, &
                                    element_symbol=element_symbol)
               WRITE (UNIT=unit_nr, FMT="(T2,I5,T8,A,T12,A,T15,6F11.5)") &
                  iatom, element_symbol, "PW", ((efg_pw(i, j, iatom), i=1, j), j=1, 3)
               WRITE (UNIT=unit_nr, FMT="(T12,A,T15,6F11.5)") &
                  "AT", ((efg_tensor(i, j, iatom) - efg_pw(i, j, iatom), i=1, j), j=1, 3)
            END IF
         END DO
         IF (unit_nr > 0) THEN
            WRITE (UNIT=unit_nr, FMT=*)
         END IF
         IF (efg_interpolation) THEN
            IF (unit_nr > 0) THEN
               WRITE (UNIT=unit_nr, FMT="(T2,A,E24.16)") "CheckSum splines =", &
                  chk_spl
               WRITE (UNIT=unit_nr, FMT=*)
            END IF
         END IF
      END IF

      DO iatom = 1, natom
         IF (unit_nr > 0) THEN
            CALL get_atomic_kind(particle_set(iatom)%atomic_kind, &
                                 element_symbol=element_symbol)
            WRITE (UNIT=unit_nr, FMT="(T2,I5,T8,A,T12,A,3(T39,3F14.7,/))") &
               iatom, element_symbol, "EFG Tensor", (efg_tensor(i, :, iatom), i=1, 3)
            WRITE (UNIT=unit_nr, FMT="(T12,A,T39,3F14.7)") &
               "EFG Tensor eigenvalues", efg_diagval(:, iatom)
            WRITE (UNIT=unit_nr, FMT="(T12,A,T67,F14.7)") "EFG Tensor anisotropy", &
               (efg_diagval(1, iatom) - efg_diagval(2, iatom))/efg_diagval(3, iatom)
            WRITE (UNIT=unit_nr, FMT=*)
         END IF
      END DO

      CALL auxbas_pw_pool%give_back_pw(v_hartree_gspace)
      IF (.NOT. efg_interpolation) THEN
         CALL auxbas_pw_pool%give_back_pw(structure_factor)
         DO i = 1, 6
            CALL auxbas_pw_pool%give_back_pw(dvr2(i))
         END DO
      ELSE
         DO i = 1, 6
            CALL auxbas_pw_pool%give_back_pw(dvspl(i))
         END DO
      END IF

      DEALLOCATE (efg_tensor)
      IF (efg_debug) THEN
         DEALLOCATE (efg_pw)
      END IF

      DEALLOCATE (vh0)

      CALL timestop(handle)

   END SUBROUTINE qs_efg_calc

! **************************************************************************************************
!> \brief ...
!> \param para_env ...
!> \param vlimit ...
!> \param rho_atom_set ...
!> \param qs_kind ...
!> \param atom_list ...
!> \param natom ...
!> \param nspins ...
! **************************************************************************************************
   SUBROUTINE vlimit_atom(para_env, vlimit, rho_atom_set, qs_kind, &
                          atom_list, natom, nspins)

      ! calculate : Limit(r->0) V_hartree(r)/r^2

      TYPE(mp_para_env_type), POINTER                    :: para_env
      REAL(dp), DIMENSION(:, -2:), INTENT(inout)         :: vlimit
      TYPE(rho_atom_type), DIMENSION(:), POINTER         :: rho_atom_set
      TYPE(qs_kind_type), INTENT(IN)                     :: qs_kind
      INTEGER, DIMENSION(:), INTENT(IN)                  :: atom_list
      INTEGER, INTENT(IN)                                :: natom, nspins

      INTEGER :: i, i1, i2, iat, iatom, icg, ipgf1, ipgf2, iset1, iset2, iso, iso1, iso1_first, &
         iso1_last, iso2, iso2_first, iso2_last, l, l_iso, llmax, m1s, m2s, m_iso, max_iso_not0, &
         max_iso_not0_local, max_s_harm, maxl, maxso, mepos, n1s, n2s, nset, num_pe, size1, size2
      INTEGER, ALLOCATABLE, DIMENSION(:)                 :: cg_n_list
      INTEGER, ALLOCATABLE, DIMENSION(:, :, :)           :: cg_list
      INTEGER, DIMENSION(2)                              :: bo
      INTEGER, DIMENSION(:), POINTER                     :: lmax, lmin, npgf, o2nindex
      REAL(dp)                                           :: zet12
      REAL(dp), ALLOCATABLE, DIMENSION(:, :)             :: CPC_sphere
      REAL(dp), DIMENSION(20)                            :: vgg
      REAL(dp), DIMENSION(:, :), POINTER                 :: coeff, zet
      REAL(dp), DIMENSION(:, :, :), POINTER              :: my_CG
      TYPE(gto_basis_set_type), POINTER                  :: basis_1c
      TYPE(harmonics_atom_type), POINTER                 :: harmonics

      NULLIFY (basis_1c)
      NULLIFY (harmonics)
      NULLIFY (lmin, lmax, npgf, zet, my_CG, coeff)

      CALL get_qs_kind(qs_kind=qs_kind, basis_set=basis_1c, basis_type="GAPW_1C", &
                       harmonics=harmonics)

      CALL get_gto_basis_set(gto_basis_set=basis_1c, lmax=lmax, lmin=lmin, &
                             maxl=maxl, npgf=npgf, nset=nset, zet=zet, &
                             maxso=maxso)
      CALL get_paw_basis_info(basis_1c, o2nindex=o2nindex)

      max_iso_not0 = harmonics%max_iso_not0
      max_s_harm = harmonics%max_s_harm
      llmax = harmonics%llmax

      ! Distribute the atoms of this kind
      num_pe = para_env%num_pe
      mepos = para_env%mepos
      bo = get_limit(natom, num_pe, mepos)

      my_CG => harmonics%my_CG

      ALLOCATE (CPC_sphere(nsoset(maxl), nsoset(maxl)))
      ALLOCATE (cg_list(2, nsoset(maxl)**2, max_s_harm), cg_n_list(max_s_harm))

      m1s = 0
      DO iset1 = 1, nset
         m2s = 0
         DO iset2 = 1, nset
            CALL get_none0_cg_list(my_CG, lmin(iset1), lmax(iset1), lmin(iset2), lmax(iset2), &
                                   max_s_harm, llmax, cg_list, cg_n_list, max_iso_not0_local)
            CPASSERT(max_iso_not0_local .LE. max_iso_not0)

            n1s = nsoset(lmax(iset1))
            DO ipgf1 = 1, npgf(iset1)
               iso1_first = nsoset(lmin(iset1) - 1) + 1 + n1s*(ipgf1 - 1) + m1s
               iso1_last = nsoset(lmax(iset1)) + n1s*(ipgf1 - 1) + m1s
               size1 = iso1_last - iso1_first + 1
               iso1_first = o2nindex(iso1_first)
               iso1_last = o2nindex(iso1_last)
               i1 = iso1_last - iso1_first + 1
               CPASSERT(size1 == i1)
               i1 = nsoset(lmin(iset1) - 1) + 1

               n2s = nsoset(lmax(iset2))
               DO ipgf2 = 1, npgf(iset2)
                  iso2_first = nsoset(lmin(iset2) - 1) + 1 + n2s*(ipgf2 - 1) + m2s
                  iso2_last = nsoset(lmax(iset2)) + n2s*(ipgf2 - 1) + m2s
                  size2 = iso2_last - iso2_first + 1
                  iso2_first = o2nindex(iso2_first)
                  iso2_last = o2nindex(iso2_last)
                  i2 = iso2_last - iso2_first + 1
                  CPASSERT(size2 == i2)
                  i2 = nsoset(lmin(iset2) - 1) + 1

                  zet12 = zet(ipgf1, iset1) + zet(ipgf2, iset2)

                  vgg = 0.0_dp

                  DO iso = 1, max_iso_not0_local
                     l_iso = indso(1, iso)
                     IF (l_iso /= 2) CYCLE
                     DO icg = 1, cg_n_list(iso)
                        iso1 = cg_list(1, icg, iso)
                        iso2 = cg_list(2, icg, iso)
                        l = indso(1, iso1) + indso(1, iso2)
                        IF (MOD(l, 2) == 0 .AND. l > 0) THEN
                           vgg(l/2) = fourpi/10._dp*fac(l - 2)/zet12**(l/2)
                        END IF
                     END DO
                  END DO

                  DO iat = bo(1), bo(2)
                     iatom = atom_list(iat)

                     CPC_sphere = 0.0_dp
                     DO i = 1, nspins
                        coeff => rho_atom_set(iatom)%cpc_h(i)%r_coef
                        CPC_sphere(i1:i1 + size1 - 1, i2:i2 + size2 - 1) = &
                           CPC_sphere(i1:i1 + size1 - 1, i2:i2 + size2 - 1) + &
                           coeff(iso1_first:iso1_last, iso2_first:iso2_last)
                        coeff => rho_atom_set(iatom)%cpc_s(i)%r_coef
                        CPC_sphere(i1:i1 + size1 - 1, i2:i2 + size2 - 1) = &
                           CPC_sphere(i1:i1 + size1 - 1, i2:i2 + size2 - 1) - &
                           coeff(iso1_first:iso1_last, iso2_first:iso2_last)
                     END DO ! i

                     DO iso = 1, max_iso_not0_local
                        l_iso = indso(1, iso)
                        m_iso = indso(1, iso)
                        IF (l_iso /= 2) CYCLE
                        DO icg = 1, cg_n_list(iso)
                           iso1 = cg_list(1, icg, iso)
                           iso2 = cg_list(2, icg, iso)
                           l = indso(1, iso1) + indso(1, iso2)
                           IF (MOD(l, 2) == 0 .AND. l > 0) THEN
                              vlimit(iatom, m_iso) = vlimit(iatom, m_iso) + &
                                                     vgg(l/2)*CPC_sphere(iso1, iso2)*my_CG(iso1, iso2, iso)
                           END IF
                        END DO ! icg
                     END DO ! iso

                  END DO ! iat

               END DO ! ipgf2
            END DO ! ipgf1
            m2s = m2s + maxso
         END DO ! iset2
         m1s = m1s + maxso
      END DO ! iset1

      CALL para_env%sum(vlimit)

      DEALLOCATE (o2nindex)
      DEALLOCATE (CPC_sphere)
      DEALLOCATE (cg_list, cg_n_list)

   END SUBROUTINE vlimit_atom

! **************************************************************************************************
!> \brief ...
!> \param ein ...
!> \param eout ...
! **************************************************************************************************
   SUBROUTINE efgsort(ein, eout)
      REAL(dp), DIMENSION(3), INTENT(in)                 :: ein
      REAL(dp), DIMENSION(3), INTENT(inout)              :: eout

      INTEGER                                            :: i
      INTEGER, DIMENSION(3)                              :: ind
      REAL(dp), DIMENSION(3)                             :: eab

      eab = ABS(ein)
      CALL sort(eab, 3, ind)
      DO i = 1, 3
         eout(i) = ein(ind(i))
      END DO

   END SUBROUTINE efgsort

END MODULE qs_electric_field_gradient

