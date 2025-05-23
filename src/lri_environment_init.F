!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief initializes the environment for lri
!>        lri : local resolution of the identity
!> \par History
!>      created [06.2015]
!> \author Dorothea Golze
! **************************************************************************************************
MODULE lri_environment_init
   USE ao_util,                         ONLY: exp_radius
   USE atomic_kind_types,               ONLY: atomic_kind_type,&
                                              get_atomic_kind_set
   USE basis_set_types,                 ONLY: copy_gto_basis_set,&
                                              gto_basis_set_type
   USE bibliography,                    ONLY: Golze2017a,&
                                              Golze2017b,&
                                              cite_reference
   USE cp_control_types,                ONLY: dft_control_type
   USE generic_shg_integrals,           ONLY: int_overlap_aba_shg
   USE generic_shg_integrals_init,      ONLY: contraction_matrix_shg,&
                                              contraction_matrix_shg_mix,&
                                              get_clebsch_gordon_coefficients
   USE input_section_types,             ONLY: section_vals_type,&
                                              section_vals_val_get
   USE kinds,                           ONLY: dp
   USE lri_environment_types,           ONLY: deallocate_bas_properties,&
                                              lri_env_create,&
                                              lri_environment_type
   USE mathconstants,                   ONLY: fac,&
                                              pi,&
                                              rootpi
   USE mathlib,                         ONLY: invert_matrix
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_environment_type
   USE qs_kind_types,                   ONLY: get_qs_kind,&
                                              qs_kind_type
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

! **************************************************************************************************

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'lri_environment_init'

   PUBLIC :: lri_env_init, lri_env_basis, lri_basis_init

! **************************************************************************************************

CONTAINS

! **************************************************************************************************
!> \brief initializes the lri env
!> \param lri_env ...
!> \param lri_section ...
! **************************************************************************************************
   SUBROUTINE lri_env_init(lri_env, lri_section)

      TYPE(lri_environment_type), POINTER                :: lri_env
      TYPE(section_vals_type), POINTER                   :: lri_section

      REAL(KIND=dp), DIMENSION(:), POINTER               :: radii

      NULLIFY (lri_env)
      ALLOCATE (lri_env)
      CALL lri_env_create(lri_env)

      ! init keywords
      ! use RI for local pp terms
      CALL section_vals_val_get(lri_section, "RI_STATISTIC", &
                                l_val=lri_env%statistics)
      ! use exact one-center terms
      CALL section_vals_val_get(lri_section, "EXACT_1C_TERMS", &
                                l_val=lri_env%exact_1c_terms)
      ! use RI for local pp terms
      CALL section_vals_val_get(lri_section, "PPL_RI", &
                                l_val=lri_env%ppl_ri)
      ! check for debug (OS scheme)
      CALL section_vals_val_get(lri_section, "DEBUG_LRI_INTEGRALS", &
                                l_val=lri_env%debug)
      ! integrals based on solid harmonic Gaussians
      CALL section_vals_val_get(lri_section, "SHG_LRI_INTEGRALS", &
                                l_val=lri_env%use_shg_integrals)
      ! how to calculate inverse/pseuodinverse of overlap
      CALL section_vals_val_get(lri_section, "LRI_OVERLAP_MATRIX", &
                                i_val=lri_env%lri_overlap_inv)
      CALL section_vals_val_get(lri_section, "MAX_CONDITION_NUM", &
                                r_val=lri_env%cond_max)
      ! integrals threshold (aba, abb)
      CALL section_vals_val_get(lri_section, "EPS_O3_INT", &
                                r_val=lri_env%eps_o3_int)
      ! RI SINV
      CALL section_vals_val_get(lri_section, "RI_SINV", &
                                c_val=lri_env%ri_sinv_app)
      ! Distant Pair Approximation
      CALL section_vals_val_get(lri_section, "DISTANT_PAIR_APPROXIMATION", &
                                l_val=lri_env%distant_pair_approximation)
      CALL section_vals_val_get(lri_section, "DISTANT_PAIR_METHOD", &
                                c_val=lri_env%distant_pair_method)
      CALL section_vals_val_get(lri_section, "DISTANT_PAIR_RADII", r_vals=radii)
      CPASSERT(SIZE(radii) == 2)
      CPASSERT(radii(2) > radii(1))
      CPASSERT(radii(1) > 0.0_dp)
      lri_env%r_in = radii(1)
      lri_env%r_out = radii(2)

      CALL cite_reference(Golze2017b)
      IF (lri_env%use_shg_integrals) CALL cite_reference(Golze2017a)

   END SUBROUTINE lri_env_init
! **************************************************************************************************
!> \brief initializes the lri env
!> \param ri_type ...
!> \param qs_env ...
!> \param lri_env ...
!> \param qs_kind_set ...
! **************************************************************************************************
   SUBROUTINE lri_env_basis(ri_type, qs_env, lri_env, qs_kind_set)

      CHARACTER(len=*), INTENT(IN)                       :: ri_type
      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(lri_environment_type), POINTER                :: lri_env
      TYPE(qs_kind_type), DIMENSION(:), POINTER          :: qs_kind_set

      INTEGER :: i, i1, i2, iat, ikind, ip, ipgf, iset, ishell, jp, l, lmax_ikind_orb, &
         lmax_ikind_ri, maxl_orb, maxl_ri, n1, n2, natom, nbas, nkind, nribas, nspin
      INTEGER, ALLOCATABLE, DIMENSION(:)                 :: kind_of
      REAL(KIND=dp)                                      :: gcc, rad, rai, raj, xradius, zeta
      REAL(KIND=dp), DIMENSION(:), POINTER               :: int_aux, norm
      TYPE(atomic_kind_type), DIMENSION(:), POINTER      :: atomic_kind_set
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(gto_basis_set_type), POINTER                  :: orb_basis_set, ri_basis_set

      ! initialize the basic basis sets (orb and ri)
      CALL get_qs_env(qs_env=qs_env, atomic_kind_set=atomic_kind_set)
      nkind = SIZE(atomic_kind_set)
      ALLOCATE (lri_env%orb_basis(nkind), lri_env%ri_basis(nkind))
      maxl_orb = 0
      maxl_ri = 0
      DO ikind = 1, nkind
         NULLIFY (orb_basis_set, ri_basis_set)
         CALL get_qs_kind(qs_kind_set(ikind), basis_set=orb_basis_set, basis_type="ORB")
         IF (ri_type == "LRI") THEN
            CALL get_qs_kind(qs_kind_set(ikind), basis_set=ri_basis_set, basis_type="LRI_AUX")
         ELSE IF (ri_type == "P_LRI") THEN
            CALL get_qs_kind(qs_kind_set(ikind), basis_set=ri_basis_set, basis_type="P_LRI_AUX")
         ELSE IF (ri_type == "RI") THEN
            CALL get_qs_kind(qs_kind_set(ikind), basis_set=ri_basis_set, basis_type="RI_HXC")
         ELSE
            CPABORT('ri_type')
         END IF
         NULLIFY (lri_env%orb_basis(ikind)%gto_basis_set)
         NULLIFY (lri_env%ri_basis(ikind)%gto_basis_set)
         IF (ASSOCIATED(orb_basis_set)) THEN
            CALL copy_gto_basis_set(orb_basis_set, lri_env%orb_basis(ikind)%gto_basis_set)
            CALL copy_gto_basis_set(ri_basis_set, lri_env%ri_basis(ikind)%gto_basis_set)
         END IF
         lmax_ikind_orb = MAXVAL(lri_env%orb_basis(ikind)%gto_basis_set%lmax)
         lmax_ikind_ri = MAXVAL(lri_env%ri_basis(ikind)%gto_basis_set%lmax)
         maxl_orb = MAX(maxl_orb, lmax_ikind_orb)
         maxl_ri = MAX(maxl_ri, lmax_ikind_ri)
      END DO

      IF ((ri_type == "LRI") .OR. (ri_type == "P_LRI")) THEN
         ! CG coefficients needed for lri integrals
         IF (ASSOCIATED(lri_env%cg_shg)) THEN
            CALL get_clebsch_gordon_coefficients(lri_env%cg_shg%cg_coeff, &
                                                 lri_env%cg_shg%cg_none0_list, &
                                                 lri_env%cg_shg%ncg_none0, &
                                                 maxl_orb, maxl_ri)
         END IF
         CALL lri_basis_init(lri_env)
         ! distant pair approximation
         IF (lri_env%distant_pair_approximation) THEN
            !
            SELECT CASE (lri_env%distant_pair_method)
            CASE ("EW")
               ! equal weight of 0.5
            CASE ("AW")
               ALLOCATE (lri_env%aradius(nkind))
               DO i = 1, nkind
                  orb_basis_set => lri_env%orb_basis(i)%gto_basis_set
                  lri_env%aradius(i) = orb_basis_set%kind_radius
               END DO
            CASE ("SW")
               ALLOCATE (lri_env%wbas(nkind))
               DO i = 1, nkind
                  orb_basis_set => lri_env%orb_basis(i)%gto_basis_set
                  n1 = orb_basis_set%nsgf
                  ALLOCATE (lri_env%wbas(i)%vec(n1))
                  DO iset = 1, orb_basis_set%nset
                     i1 = orb_basis_set%first_sgf(1, iset)
                     n2 = orb_basis_set%nshell(iset)
                     i2 = orb_basis_set%last_sgf(n2, iset)
                     lri_env%wbas(i)%vec(i1:i2) = orb_basis_set%set_radius(iset)
                  END DO
               END DO
            CASE ("LW")
               ALLOCATE (lri_env%wbas(nkind))
               DO i = 1, nkind
                  orb_basis_set => lri_env%orb_basis(i)%gto_basis_set
                  n1 = orb_basis_set%nsgf
                  ALLOCATE (lri_env%wbas(i)%vec(n1))
                  DO iset = 1, orb_basis_set%nset
                     DO ishell = 1, orb_basis_set%nshell(iset)
                        i1 = orb_basis_set%first_sgf(ishell, iset)
                        i2 = orb_basis_set%last_sgf(ishell, iset)
                        l = orb_basis_set%l(ishell, iset)
                        xradius = 0.0_dp
                        DO ipgf = 1, orb_basis_set%npgf(iset)
                           gcc = orb_basis_set%gcc(ipgf, ishell, iset)
                           zeta = orb_basis_set%zet(ipgf, iset)
                           rad = exp_radius(l, zeta, 1.e-5_dp, gcc, rlow=xradius)
                           xradius = MAX(xradius, rad)
                        END DO
                        lri_env%wbas(i)%vec(i1:i2) = xradius
                     END DO
                  END DO
               END DO
            CASE DEFAULT
               CPABORT("Unknown DISTANT_PAIR_METHOD in LRI")
            END SELECT
            !
            ALLOCATE (lri_env%wmat(nkind, nkind))
            SELECT CASE (lri_env%distant_pair_method)
            CASE ("EW")
               ! equal weight of 0.5
               DO i1 = 1, nkind
                  n1 = lri_env%orb_basis(i1)%gto_basis_set%nsgf
                  DO i2 = 1, nkind
                     n2 = lri_env%orb_basis(i2)%gto_basis_set%nsgf
                     ALLOCATE (lri_env%wmat(i1, i2)%mat(n1, n2))
                     lri_env%wmat(i1, i2)%mat(:, :) = 0.5_dp
                  END DO
               END DO
            CASE ("AW")
               DO i1 = 1, nkind
                  n1 = lri_env%orb_basis(i1)%gto_basis_set%nsgf
                  DO i2 = 1, nkind
                     n2 = lri_env%orb_basis(i2)%gto_basis_set%nsgf
                     ALLOCATE (lri_env%wmat(i1, i2)%mat(n1, n2))
                     rai = lri_env%aradius(i1)**2
                     raj = lri_env%aradius(i2)**2
                     IF (raj > rai) THEN
                        lri_env%wmat(i1, i2)%mat(:, :) = 1.0_dp
                     ELSE
                        lri_env%wmat(i1, i2)%mat(:, :) = 0.0_dp
                     END IF
                  END DO
               END DO
            CASE ("SW", "LW")
               DO i1 = 1, nkind
                  n1 = lri_env%orb_basis(i1)%gto_basis_set%nsgf
                  DO i2 = 1, nkind
                     n2 = lri_env%orb_basis(i2)%gto_basis_set%nsgf
                     ALLOCATE (lri_env%wmat(i1, i2)%mat(n1, n2))
                     DO ip = 1, SIZE(lri_env%wbas(i1)%vec)
                        rai = lri_env%wbas(i1)%vec(ip)**2
                        DO jp = 1, SIZE(lri_env%wbas(i2)%vec)
                           raj = lri_env%wbas(i2)%vec(jp)**2
                           IF (raj > rai) THEN
                              lri_env%wmat(i1, i2)%mat(ip, jp) = 1.0_dp
                           ELSE
                              lri_env%wmat(i1, i2)%mat(ip, jp) = 0.0_dp
                           END IF
                        END DO
                     END DO
                  END DO
               END DO
            END SELECT
         END IF
      ELSE IF (ri_type == "RI") THEN
         ALLOCATE (lri_env%ri_fit)
         NULLIFY (lri_env%ri_fit%nvec)
         NULLIFY (lri_env%ri_fit%bas_ptr)
         CALL get_qs_env(qs_env=qs_env, natom=natom)
         ! initialize pointers to RI basis vector
         ALLOCATE (lri_env%ri_fit%bas_ptr(2, natom))
         ALLOCATE (kind_of(natom))
         CALL get_atomic_kind_set(atomic_kind_set, kind_of=kind_of)
         nbas = 0
         DO iat = 1, natom
            ikind = kind_of(iat)
            nribas = lri_env%ri_basis(ikind)%gto_basis_set%nsgf
            lri_env%ri_fit%bas_ptr(1, iat) = nbas + 1
            lri_env%ri_fit%bas_ptr(2, iat) = nbas + nribas
            nbas = nbas + nribas
         END DO
         ! initialize vector t
         CALL get_qs_env(qs_env=qs_env, dft_control=dft_control)
         nspin = dft_control%nspins
         ALLOCATE (lri_env%ri_fit%tvec(nbas, nspin), lri_env%ri_fit%rm1t(nbas, nspin))
         ! initialize vector a, expansion of density
         ALLOCATE (lri_env%ri_fit%avec(nbas, nspin))
         ! initialize vector fout, R^(-1)*(f-p*n)
         ALLOCATE (lri_env%ri_fit%fout(nbas, nspin))
         ! initialize vector with RI basis integrated
         NULLIFY (norm, int_aux)
         nbas = lri_env%ri_fit%bas_ptr(2, natom)
         ALLOCATE (lri_env%ri_fit%nvec(nbas), lri_env%ri_fit%rm1n(nbas))
         ikind = 0
         DO iat = 1, natom
            IF (ikind /= kind_of(iat)) THEN
               ikind = kind_of(iat)
               ri_basis_set => lri_env%ri_basis(ikind)%gto_basis_set
               IF (ASSOCIATED(norm)) DEALLOCATE (norm)
               IF (ASSOCIATED(int_aux)) DEALLOCATE (int_aux)
               CALL basis_norm_s_func(ri_basis_set, norm)
               CALL basis_int(ri_basis_set, int_aux, norm)
            END IF
            nbas = SIZE(int_aux)
            i1 = lri_env%ri_fit%bas_ptr(1, iat)
            i2 = lri_env%ri_fit%bas_ptr(2, iat)
            lri_env%ri_fit%nvec(i1:i2) = int_aux(1:nbas)
         END DO
         IF (ASSOCIATED(norm)) DEALLOCATE (norm)
         IF (ASSOCIATED(int_aux)) DEALLOCATE (int_aux)
         DEALLOCATE (kind_of)
      ELSE
         CPABORT('ri_type')
      END IF

   END SUBROUTINE lri_env_basis

! **************************************************************************************************
!> \brief initializes the lri basis: calculates the norm, self-overlap
!>        and integral of the ri basis
!> \param lri_env ...
! **************************************************************************************************
   SUBROUTINE lri_basis_init(lri_env)
      TYPE(lri_environment_type), POINTER                :: lri_env

      INTEGER                                            :: ikind, nkind
      INTEGER, DIMENSION(:, :, :), POINTER               :: orb_index, ri_index
      REAL(KIND=dp)                                      :: delta
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:, :, :, :)  :: dovlp3
      REAL(KIND=dp), DIMENSION(:), POINTER               :: orb_norm_r, ri_int_fbas, ri_norm_r, &
                                                            ri_norm_s
      REAL(KIND=dp), DIMENSION(:, :), POINTER            :: orb_ovlp, ri_ovlp, ri_ovlp_inv
      REAL(KIND=dp), DIMENSION(:, :, :), POINTER         :: scon_orb, scon_ri
      REAL(KIND=dp), DIMENSION(:, :, :, :), POINTER      :: scon_mix
      TYPE(gto_basis_set_type), POINTER                  :: orb_basis, ri_basis

      IF (ASSOCIATED(lri_env)) THEN
         IF (ASSOCIATED(lri_env%orb_basis)) THEN
            CPASSERT(ASSOCIATED(lri_env%ri_basis))
            nkind = SIZE(lri_env%orb_basis)
            CALL deallocate_bas_properties(lri_env)
            ALLOCATE (lri_env%bas_prop(nkind))
            DO ikind = 1, nkind
               NULLIFY (orb_basis, ri_basis)
               orb_basis => lri_env%orb_basis(ikind)%gto_basis_set
               IF (ASSOCIATED(orb_basis)) THEN
                  ri_basis => lri_env%ri_basis(ikind)%gto_basis_set
                  CPASSERT(ASSOCIATED(ri_basis))
                  NULLIFY (ri_norm_r)
                  CALL basis_norm_radial(ri_basis, ri_norm_r)
                  NULLIFY (orb_norm_r)
                  CALL basis_norm_radial(orb_basis, orb_norm_r)
                  NULLIFY (ri_norm_s)
                  CALL basis_norm_s_func(ri_basis, ri_norm_s)
                  NULLIFY (ri_int_fbas)
                  CALL basis_int(ri_basis, ri_int_fbas, ri_norm_s)
                  lri_env%bas_prop(ikind)%int_fbas => ri_int_fbas
                  NULLIFY (ri_ovlp)
                  CALL basis_ovlp(ri_basis, ri_ovlp, ri_norm_r)
                  lri_env%bas_prop(ikind)%ri_ovlp => ri_ovlp
                  NULLIFY (orb_ovlp)
                  CALL basis_ovlp(orb_basis, orb_ovlp, orb_norm_r)
                  lri_env%bas_prop(ikind)%orb_ovlp => orb_ovlp
                  NULLIFY (scon_ri)
                  CALL contraction_matrix_shg(ri_basis, scon_ri)
                  lri_env%bas_prop(ikind)%scon_ri => scon_ri
                  NULLIFY (scon_orb)
                  CALL contraction_matrix_shg(orb_basis, scon_orb)
                  lri_env%bas_prop(ikind)%scon_orb => scon_orb
                  NULLIFY (scon_mix)
                  CALL contraction_matrix_shg_mix(orb_basis, ri_basis, &
                                                  orb_index, ri_index, scon_mix)
                  lri_env%bas_prop(ikind)%scon_mix => scon_mix
                  lri_env%bas_prop(ikind)%orb_index => orb_index
                  lri_env%bas_prop(ikind)%ri_index => ri_index
                  ALLOCATE (lri_env%bas_prop(ikind)%ovlp3(orb_basis%nsgf, orb_basis%nsgf, ri_basis%nsgf))
                  ALLOCATE (dovlp3(orb_basis%nsgf, orb_basis%nsgf, ri_basis%nsgf, 3))
                  CALL int_overlap_aba_shg(lri_env%bas_prop(ikind)%ovlp3, dovlp3, (/0.0_dp, 0.0_dp, 0.0_dp/), &
                                           orb_basis, orb_basis, ri_basis, scon_orb, &
                                           scon_mix, orb_index, ri_index, &
                                           lri_env%cg_shg%cg_coeff, &
                                           lri_env%cg_shg%cg_none0_list, &
                                           lri_env%cg_shg%ncg_none0, &
                                           calculate_forces=.FALSE.)
                  DEALLOCATE (orb_norm_r, ri_norm_r, ri_norm_s)
                  DEALLOCATE (dovlp3)
                  ALLOCATE (ri_ovlp_inv(ri_basis%nsgf, ri_basis%nsgf))
                  CALL invert_matrix(ri_ovlp, ri_ovlp_inv, delta, improve=.TRUE.)
                  lri_env%bas_prop(ikind)%ri_ovlp_inv => ri_ovlp_inv
               END IF
            END DO
         END IF
      END IF

   END SUBROUTINE lri_basis_init

! **************************************************************************************************
!> \brief normalization for a contracted Gaussian s-function,
!>        spherical = cartesian Gaussian for s-functions
!> \param basis ...
!> \param norm ...
! **************************************************************************************************
   SUBROUTINE basis_norm_s_func(basis, norm)

      TYPE(gto_basis_set_type), POINTER                  :: basis
      REAL(dp), DIMENSION(:), POINTER                    :: norm

      INTEGER                                            :: ipgf, iset, isgf, ishell, jpgf, l, nbas
      REAL(KIND=dp)                                      :: aai, aaj, cci, ccj, expa, ppl

      NULLIFY (norm)

      nbas = basis%nsgf
      ALLOCATE (norm(nbas))
      norm = 0._dp

      DO iset = 1, basis%nset
         DO ishell = 1, basis%nshell(iset)
            l = basis%l(ishell, iset)
            IF (l /= 0) CYCLE
            expa = 0.5_dp*REAL(2*l + 3, dp)
            ppl = pi**(3._dp/2._dp)
            DO isgf = basis%first_sgf(ishell, iset), basis%last_sgf(ishell, iset)
               DO ipgf = 1, basis%npgf(iset)
                  cci = basis%gcc(ipgf, ishell, iset)
                  aai = basis%zet(ipgf, iset)
                  DO jpgf = 1, basis%npgf(iset)
                     ccj = basis%gcc(jpgf, ishell, iset)
                     aaj = basis%zet(jpgf, iset)
                     norm(isgf) = norm(isgf) + cci*ccj*ppl/(aai + aaj)**expa
                  END DO
               END DO
               norm(isgf) = 1.0_dp/SQRT(norm(isgf))
            END DO
         END DO
      END DO

   END SUBROUTINE basis_norm_s_func

! **************************************************************************************************
!> \brief normalization for radial part of contracted spherical Gaussian
!>        functions
!> \param basis ...
!> \param norm ...
! **************************************************************************************************
   SUBROUTINE basis_norm_radial(basis, norm)

      TYPE(gto_basis_set_type), POINTER                  :: basis
      REAL(dp), DIMENSION(:), POINTER                    :: norm

      INTEGER                                            :: ipgf, iset, isgf, ishell, jpgf, l, nbas
      REAL(KIND=dp)                                      :: aai, aaj, cci, ccj, expa, ppl

      NULLIFY (norm)

      nbas = basis%nsgf
      ALLOCATE (norm(nbas))
      norm = 0._dp

      DO iset = 1, basis%nset
         DO ishell = 1, basis%nshell(iset)
            l = basis%l(ishell, iset)
            expa = 0.5_dp*REAL(2*l + 3, dp)
            ppl = fac(2*l + 2)*rootpi/2._dp**REAL(2*l + 3, dp)/fac(l + 1)
            DO isgf = basis%first_sgf(ishell, iset), basis%last_sgf(ishell, iset)
               DO ipgf = 1, basis%npgf(iset)
                  cci = basis%gcc(ipgf, ishell, iset)
                  aai = basis%zet(ipgf, iset)
                  DO jpgf = 1, basis%npgf(iset)
                     ccj = basis%gcc(jpgf, ishell, iset)
                     aaj = basis%zet(jpgf, iset)
                     norm(isgf) = norm(isgf) + cci*ccj*ppl/(aai + aaj)**expa
                  END DO
               END DO
               norm(isgf) = 1.0_dp/SQRT(norm(isgf))
            END DO
         END DO
      END DO

   END SUBROUTINE basis_norm_radial

!*****************************************************************************
!> \brief integral over a single (contracted) lri auxiliary basis function,
!>        integral is zero for all but s-functions
!> \param basis ...
!> \param int_aux ...
!> \param norm ...
! **************************************************************************************************
   SUBROUTINE basis_int(basis, int_aux, norm)

      TYPE(gto_basis_set_type), POINTER                  :: basis
      REAL(dp), DIMENSION(:), POINTER                    :: int_aux, norm

      INTEGER                                            :: ipgf, iset, isgf, ishell, l, nbas
      REAL(KIND=dp)                                      :: aa, cc, pp

      nbas = basis%nsgf
      ALLOCATE (int_aux(nbas))
      int_aux = 0._dp

      DO iset = 1, basis%nset
         DO ishell = 1, basis%nshell(iset)
            l = basis%l(ishell, iset)
            IF (l /= 0) CYCLE
            DO isgf = basis%first_sgf(ishell, iset), basis%last_sgf(ishell, iset)
               DO ipgf = 1, basis%npgf(iset)
                  cc = basis%gcc(ipgf, ishell, iset)
                  aa = basis%zet(ipgf, iset)
                  pp = (pi/aa)**(3._dp/2._dp)
                  int_aux(isgf) = int_aux(isgf) + norm(isgf)*cc*pp
               END DO
            END DO
         END DO
      END DO

   END SUBROUTINE basis_int

!*****************************************************************************
!> \brief self-overlap of lri basis for contracted spherical Gaussians.
!>        Overlap of radial part. Norm contains only normalization of radial
!>        part. Norm and overlap of spherical harmonics not explicitly
!>        calculated since this cancels for the self-overlap anyway.
!> \param basis ...
!> \param ovlp ...
!> \param norm ...
! **************************************************************************************************
   SUBROUTINE basis_ovlp(basis, ovlp, norm)

      TYPE(gto_basis_set_type), POINTER                  :: basis
      REAL(dp), DIMENSION(:, :), POINTER                 :: ovlp
      REAL(dp), DIMENSION(:), POINTER                    :: norm

      INTEGER                                            :: ipgf, iset, isgf, ishell, jpgf, jset, &
                                                            jsgf, jshell, l, li, lj, m_i, m_j, nbas
      REAL(KIND=dp)                                      :: aai, aaj, cci, ccj, expa, norm_i, &
                                                            norm_j, oo, ppl

      nbas = basis%nsgf
      ALLOCATE (ovlp(nbas, nbas))
      ovlp = 0._dp

      DO iset = 1, basis%nset
         DO ishell = 1, basis%nshell(iset)
            li = basis%l(ishell, iset)
            DO jset = 1, basis%nset
               DO jshell = 1, basis%nshell(jset)
                  lj = basis%l(jshell, jset)
                  IF (li == lj) THEN
                     l = li
                     expa = 0.5_dp*REAL(2*l + 3, dp)
                     ppl = fac(2*l + 2)*rootpi/2._dp**REAL(2*l + 3, dp)/fac(l + 1)
                     DO isgf = basis%first_sgf(ishell, iset), basis%last_sgf(ishell, iset)
                        m_i = basis%m(isgf)
                        DO jsgf = basis%first_sgf(jshell, jset), basis%last_sgf(jshell, jset)
                           m_j = basis%m(jsgf)
                           IF (m_i == m_j) THEN
                              DO ipgf = 1, basis%npgf(iset)
                                 cci = basis%gcc(ipgf, ishell, iset)
                                 aai = basis%zet(ipgf, iset)
                                 norm_i = norm(isgf)
                                 DO jpgf = 1, basis%npgf(jset)
                                    ccj = basis%gcc(jpgf, jshell, jset)
                                    aaj = basis%zet(jpgf, jset)
                                    oo = 1._dp/(aai + aaj)**expa
                                    norm_j = norm(jsgf)
                                    ovlp(isgf, jsgf) = ovlp(isgf, jsgf) + norm_i*norm_j*ppl*cci*ccj*oo
                                 END DO
                              END DO
                           END IF
                        END DO
                     END DO
                  END IF
               END DO
            END DO
         END DO
      END DO

   END SUBROUTINE basis_ovlp

END MODULE lri_environment_init
