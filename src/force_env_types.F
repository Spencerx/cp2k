!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Interface for the force calculations
!> \par History
!>      cjm, FEB-20-2001: pass variable box_ref
!>      cjm, SEPT-12-2002: major reorganization
!>      fawzi, APR-12-2003: introduced force_env
!>      cjm, FEB-27-2006: no more box_change
!>      MK, Nov. 2010: new interfaces added and others were updated
!> \author CJM & JGH
! **************************************************************************************************
MODULE force_env_types
   USE cell_types,                      ONLY: cell_type
   USE cp_log_handling,                 ONLY: cp_add_default_logger,&
                                              cp_logger_type,&
                                              cp_rm_default_logger
   USE cp_subsys_types,                 ONLY: cp_subsys_get,&
                                              cp_subsys_type,&
                                              pack_subsys_particles
   USE eip_environment_types,           ONLY: eip_env_get,&
                                              eip_env_release,&
                                              eip_environment_type
   USE embed_types,                     ONLY: embed_env_release,&
                                              embed_env_type,&
                                              get_embed_env
   USE fist_energy_types,               ONLY: fist_energy_type
   USE fist_environment_types,          ONLY: fist_env_get,&
                                              fist_env_release,&
                                              fist_environment_type
   USE fp_types,                        ONLY: fp_env_release,&
                                              fp_type
   USE global_types,                    ONLY: global_environment_type,&
                                              globenv_release
   USE input_section_types,             ONLY: section_vals_get,&
                                              section_vals_release,&
                                              section_vals_retain,&
                                              section_vals_type,&
                                              section_vals_val_get
   USE ipi_environment_types,           ONLY: ipi_env_get,&
                                              ipi_env_release,&
                                              ipi_environment_type
   USE ipi_server,                      ONLY: shutdown_server
   USE kinds,                           ONLY: dp
   USE message_passing,                 ONLY: mp_para_env_release,&
                                              mp_para_env_type
   USE metadynamics_types,              ONLY: meta_env_release,&
                                              meta_env_type
   USE mixed_energy_types,              ONLY: mixed_energy_type
   USE mixed_environment_types,         ONLY: get_mixed_env,&
                                              mixed_env_release,&
                                              mixed_environment_type
   USE nnp_environment_types,           ONLY: nnp_env_get,&
                                              nnp_env_release,&
                                              nnp_type
   USE pwdft_environment_types,         ONLY: pwdft_energy_type,&
                                              pwdft_env_get,&
                                              pwdft_env_release,&
                                              pwdft_environment_type
   USE qmmm_types,                      ONLY: qmmm_env_get,&
                                              qmmm_env_release,&
                                              qmmm_env_type
   USE qmmmx_types,                     ONLY: qmmmx_env_get,&
                                              qmmmx_env_release,&
                                              qmmmx_env_type
   USE qs_energy_types,                 ONLY: qs_energy_type
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_env_release,&
                                              qs_environment_type
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'force_env_types'

   INTEGER, PARAMETER, PUBLIC :: use_fist_force = 501, &
                                 use_qs_force = 502, &
                                 use_qmmm = 503, &
                                 use_qmmmx = 504, &
                                 use_eip_force = 505, &
                                 use_mixed_force = 506, &
                                 use_embed = 507, &
                                 use_pwdft_force = 508, &
                                 use_nnp_force = 509, &
                                 use_ipi = 510

   CHARACTER(LEN=10), DIMENSION(501:510), PARAMETER, PUBLIC :: &
      use_prog_name = (/ &
      "FIST  ", &
      "QS    ", &
      "QMMM  ", &
      "QMMMX ", &
      "EIP   ", &
      "MIXED ", &
      "EMBED ", &
      "SIRIUS", &
      "NNP   ", &
      "IPI   "/)

   PUBLIC :: force_env_type, &
             force_env_p_type

   PUBLIC :: force_env_retain, &
             force_env_release, &
             force_env_get, &
             force_env_get_natom, &
             force_env_get_nparticle, &
             force_env_get_frc, &
             force_env_get_pos, &
             force_env_get_vel, &
             force_env_set, &
             multiple_fe_list

! **************************************************************************************************
!> \brief wrapper to abstract the force evaluation of the various methods
!> \param ref_count reference count (see doc/ReferenceCounting.html)
!> \param in_use which method is in use
!> \param fist_env the fist environment (allocated only if fist is in use)
!> \param qs_env qs_env (activated only if quickstep is in use)
!> \param globenv the globenv to have the input that generated this force_env
!> \param para_env the parallel environment that contains all the parallel
!>        environment of the fragments
!> \param meta_env the metadynamics environment, allocated if there is
!>        metadynamics
!> \param fp_env the flexible partitioning environment
!>      read-only attributes (get them *only* through force_env_get):
!> \param subsys the fragments that build up the actual system.
!> \param cell the cell of the actual system
!> \note
!>      as always direct manipulation of these attributes can have very
!>      bad effects. In this case it can be quite bad and the variables
!>      might not be up to date. You are warned, use only the get method...
!> \par History
!>      04.2003 created [fawzi]
!>      07.2003 tried to adapt to multiple mpi groups
!> \author fawzi
! **************************************************************************************************
   TYPE force_env_type
      INTEGER :: ref_count = 0, in_use = 0, method_name_id = 0
      REAL(KIND=dp)                                    :: additional_potential = 0.0_dp
      TYPE(fist_environment_type), POINTER             :: fist_env => NULL()
      TYPE(meta_env_type), POINTER                     :: meta_env => NULL()
      TYPE(fp_type), POINTER                           :: fp_env => NULL()
      TYPE(qs_environment_type), POINTER               :: qs_env => NULL()
      TYPE(eip_environment_type), POINTER              :: eip_env => NULL()
      TYPE(pwdft_environment_type), POINTER            :: pwdft_env => NULL()
      TYPE(global_environment_type), POINTER           :: globenv => NULL()
      TYPE(mp_para_env_type), POINTER                  :: para_env => NULL()
      TYPE(force_env_p_type), DIMENSION(:), POINTER    :: sub_force_env => NULL()
      TYPE(qmmm_env_type), POINTER                     :: qmmm_env => NULL()
      TYPE(qmmmx_env_type), POINTER                    :: qmmmx_env => NULL()
      TYPE(mixed_environment_type), POINTER            :: mixed_env => NULL()
      TYPE(nnp_type), POINTER                          :: nnp_env => NULL()
      TYPE(embed_env_type), POINTER                    :: embed_env => NULL()
      TYPE(ipi_environment_type), POINTER              :: ipi_env => NULL()
      TYPE(section_vals_type), POINTER                 :: force_env_section => NULL()
      TYPE(section_vals_type), POINTER                 :: root_section => NULL()
   END TYPE force_env_type

! **************************************************************************************************
!> \brief allows for the creation of an array of force_env
!> \param force_env a force environment (see above)
!> \note
!>      added by MJM for MC swap moves
!> \author MJM
! **************************************************************************************************
   TYPE force_env_p_type
      TYPE(force_env_type), POINTER :: force_env => NULL()
   END TYPE force_env_p_type

CONTAINS

! **************************************************************************************************
!> \brief retains the given force env
!> \param force_env the force environment to retain
!> \par History
!>      04.2003 created [fawzi]
!> \author fawzi
!> \note
!>      see doc/ReferenceCounting.html
! **************************************************************************************************
   SUBROUTINE force_env_retain(force_env)
      TYPE(force_env_type), POINTER                      :: force_env

      CPASSERT(ASSOCIATED(force_env))
      CPASSERT(force_env%ref_count > 0)
      force_env%ref_count = force_env%ref_count + 1
   END SUBROUTINE force_env_retain

! **************************************************************************************************
!> \brief releases the given force env
!> \param force_env the force environment to release
!> \par History
!>      04.2003 created [fawzi]
!> \author fawzi
!> \note
!>      see doc/ReferenceCounting.html
! **************************************************************************************************
   RECURSIVE SUBROUTINE force_env_release(force_env)
      TYPE(force_env_type), POINTER                      :: force_env

      INTEGER                                            :: i, my_group
      TYPE(cp_logger_type), POINTER                      :: my_logger

      IF (ASSOCIATED(force_env)) THEN
         CPASSERT(force_env%ref_count > 0)
         force_env%ref_count = force_env%ref_count - 1
         IF (force_env%ref_count == 0) THEN
            ! Deallocate SUB_FORCE_ENV
            IF (ASSOCIATED(force_env%sub_force_env)) THEN
               DO i = 1, SIZE(force_env%sub_force_env)
                  IF (.NOT. ASSOCIATED(force_env%sub_force_env(i)%force_env)) CYCLE
                  ! Use the proper logger to deallocate..
                  IF (force_env%in_use == use_mixed_force) THEN
                     my_group = force_env%mixed_env%group_distribution(force_env%para_env%mepos)
                     my_logger => force_env%mixed_env%sub_logger(my_group + 1)%p
                     CALL cp_add_default_logger(my_logger)
                  END IF
                  ! The same for embedding
                  IF (force_env%in_use == use_embed) THEN
                     my_group = force_env%embed_env%group_distribution(force_env%para_env%mepos)
                     my_logger => force_env%embed_env%sub_logger(my_group + 1)%p
                     CALL cp_add_default_logger(my_logger)
                  END IF
                  CALL force_env_release(force_env%sub_force_env(i)%force_env)
                  IF (force_env%in_use == use_mixed_force) &
                     CALL cp_rm_default_logger()
                  IF (force_env%in_use == use_embed) &
                     CALL cp_rm_default_logger()
               END DO
               DEALLOCATE (force_env%sub_force_env)
            END IF

            SELECT CASE (force_env%in_use)
            CASE (use_fist_force)
               CALL fist_env_release(force_env%fist_env)
               DEALLOCATE (force_env%fist_env)
            CASE (use_qs_force)
               CALL qs_env_release(force_env%qs_env)
               DEALLOCATE (force_env%qs_env)
            CASE (use_eip_force)
               CALL eip_env_release(force_env%eip_env)
               DEALLOCATE (force_env%eip_env)
            CASE (use_pwdft_force)
               CALL pwdft_env_release(force_env%pwdft_env)
               DEALLOCATE (force_env%pwdft_env)
            CASE (use_mixed_force)
               CALL mixed_env_release(force_env%mixed_env)
               DEALLOCATE (force_env%mixed_env)
            CASE (use_nnp_force)
               CALL nnp_env_release(force_env%nnp_env)
               DEALLOCATE (force_env%nnp_env)
            CASE (use_embed)
               CALL embed_env_release(force_env%embed_env)
               DEALLOCATE (force_env%embed_env)
            CASE (use_ipi)
               CALL shutdown_server(force_env%ipi_env)
               CALL ipi_env_release(force_env%ipi_env)
               DEALLOCATE (force_env%ipi_env)
            END SELECT
            CALL globenv_release(force_env%globenv)
            CALL mp_para_env_release(force_env%para_env)
            ! Not deallocated
            CPASSERT(.NOT. ASSOCIATED(force_env%fist_env))
            CPASSERT(.NOT. ASSOCIATED(force_env%qs_env))
            CPASSERT(.NOT. ASSOCIATED(force_env%eip_env))
            CPASSERT(.NOT. ASSOCIATED(force_env%pwdft_env))
            CPASSERT(.NOT. ASSOCIATED(force_env%mixed_env))
            CPASSERT(.NOT. ASSOCIATED(force_env%nnp_env))
            CPASSERT(.NOT. ASSOCIATED(force_env%embed_env))
            CPASSERT(.NOT. ASSOCIATED(force_env%ipi_env))
            IF (ASSOCIATED(force_env%meta_env)) THEN
               CALL meta_env_release(force_env%meta_env)
               DEALLOCATE (force_env%meta_env)
            END IF
            IF (ASSOCIATED(force_env%fp_env)) THEN
               CALL fp_env_release(force_env%fp_env)
               DEALLOCATE (force_env%fp_env)
            END IF
            IF (ASSOCIATED(force_env%qmmm_env)) THEN
               CALL qmmm_env_release(force_env%qmmm_env)
               DEALLOCATE (force_env%qmmm_env)
            END IF
            IF (ASSOCIATED(force_env%qmmmx_env)) THEN
               CALL qmmmx_env_release(force_env%qmmmx_env)
               DEALLOCATE (force_env%qmmmx_env)
            END IF
            CALL section_vals_release(force_env%force_env_section)
            CALL section_vals_release(force_env%root_section)
            DEALLOCATE (force_env)
         END IF
      END IF
      NULLIFY (force_env)
   END SUBROUTINE force_env_release

! **************************************************************************************************
!> \brief returns various attributes about the force environment
!> \param force_env the force environment you what informations about
!> \param in_use ...
!> \param fist_env ...
!> \param qs_env ...
!> \param meta_env ...
!> \param fp_env ...
!> \param subsys ...
!> \param para_env ...
!> \param potential_energy ...
!> \param additional_potential ...
!> \param kinetic_energy ...
!> \param harmonic_shell ...
!> \param kinetic_shell ...
!> \param cell ...
!> \param sub_force_env ...
!> \param qmmm_env ...
!> \param qmmmx_env ...
!> \param eip_env ...
!> \param pwdft_env ...
!> \param globenv ...
!> \param input ...
!> \param force_env_section ...
!> \param method_name_id ...
!> \param root_section ...
!> \param mixed_env ...
!> \param nnp_env ...
!> \param embed_env ...
!> \param ipi_env ...
!> \par History
!>      04.2003 created [fawzi]
!> \author fawzi
! **************************************************************************************************
   RECURSIVE SUBROUTINE force_env_get(force_env, in_use, fist_env, qs_env, &
                                      meta_env, fp_env, subsys, para_env, potential_energy, additional_potential, &
                                      kinetic_energy, harmonic_shell, kinetic_shell, cell, sub_force_env, &
                                      qmmm_env, qmmmx_env, eip_env, pwdft_env, globenv, input, force_env_section, &
                                      method_name_id, root_section, mixed_env, nnp_env, embed_env, ipi_env)
      TYPE(force_env_type), INTENT(IN)                   :: force_env
      INTEGER, INTENT(out), OPTIONAL                     :: in_use
      TYPE(fist_environment_type), OPTIONAL, POINTER     :: fist_env
      TYPE(qs_environment_type), OPTIONAL, POINTER       :: qs_env
      TYPE(meta_env_type), OPTIONAL, POINTER             :: meta_env
      TYPE(fp_type), OPTIONAL, POINTER                   :: fp_env
      TYPE(cp_subsys_type), OPTIONAL, POINTER            :: subsys
      TYPE(mp_para_env_type), OPTIONAL, POINTER          :: para_env
      REAL(KIND=dp), INTENT(OUT), OPTIONAL               :: potential_energy, additional_potential, &
                                                            kinetic_energy, harmonic_shell, &
                                                            kinetic_shell
      TYPE(cell_type), OPTIONAL, POINTER                 :: cell
      TYPE(force_env_p_type), DIMENSION(:), OPTIONAL, &
         POINTER                                         :: sub_force_env
      TYPE(qmmm_env_type), OPTIONAL, POINTER             :: qmmm_env
      TYPE(qmmmx_env_type), OPTIONAL, POINTER            :: qmmmx_env
      TYPE(eip_environment_type), OPTIONAL, POINTER      :: eip_env
      TYPE(pwdft_environment_type), OPTIONAL, POINTER    :: pwdft_env
      TYPE(global_environment_type), OPTIONAL, POINTER   :: globenv
      TYPE(section_vals_type), OPTIONAL, POINTER         :: input, force_env_section
      INTEGER, INTENT(out), OPTIONAL                     :: method_name_id
      TYPE(section_vals_type), OPTIONAL, POINTER         :: root_section
      TYPE(mixed_environment_type), OPTIONAL, POINTER    :: mixed_env
      TYPE(nnp_type), OPTIONAL, POINTER                  :: nnp_env
      TYPE(embed_env_type), OPTIONAL, POINTER            :: embed_env
      TYPE(ipi_environment_type), OPTIONAL, POINTER      :: ipi_env

      REAL(KIND=dp)                                      :: eip_kinetic_energy, eip_potential_energy
      TYPE(cp_subsys_type), POINTER                      :: subsys_tmp
      TYPE(fist_energy_type), POINTER                    :: thermo
      TYPE(mixed_energy_type), POINTER                   :: mixed_energy
      TYPE(pwdft_energy_type), POINTER                   :: pwdft_energy
      TYPE(qs_energy_type), POINTER                      :: qs_energy

      NULLIFY (subsys_tmp)

      CPASSERT(force_env%ref_count > 0)

      SELECT CASE (force_env%in_use)
      CASE (use_qs_force)
         CPASSERT(ASSOCIATED(force_env%qs_env))
         CPASSERT(.NOT. PRESENT(fist_env))
         CPASSERT(.NOT. PRESENT(eip_env))
         CPASSERT(.NOT. PRESENT(pwdft_env))
         CPASSERT(.NOT. PRESENT(ipi_env))
         CALL get_qs_env(force_env%qs_env, &
                         energy=qs_energy, &
                         input=input, &
                         cp_subsys=subsys)
         IF (PRESENT(potential_energy)) potential_energy = qs_energy%total
         CPASSERT(.NOT. PRESENT(kinetic_energy))
      CASE (use_fist_force)
         CPASSERT(ASSOCIATED(force_env%fist_env))
         CPASSERT(.NOT. PRESENT(input))
         CALL fist_env_get(force_env%fist_env, &
                           thermo=thermo, &
                           subsys=subsys)
         IF (PRESENT(potential_energy)) potential_energy = thermo%pot
         IF (PRESENT(kinetic_energy)) kinetic_energy = thermo%kin
         IF (PRESENT(kinetic_shell)) kinetic_shell = thermo%kin_shell
         IF (PRESENT(harmonic_shell)) harmonic_shell = thermo%harm_shell
      CASE (use_eip_force)
         CPASSERT(ASSOCIATED(force_env%eip_env))
         CPASSERT(.NOT. PRESENT(qs_env))
         CPASSERT(.NOT. PRESENT(fist_env))
         CPASSERT(.NOT. PRESENT(ipi_env))
         CALL eip_env_get(force_env%eip_env, &
                          eip_potential_energy=eip_potential_energy, &
                          eip_kinetic_energy=eip_kinetic_energy, &
                          subsys=subsys)
         IF (PRESENT(potential_energy)) THEN
            potential_energy = eip_potential_energy
         END IF
         IF (PRESENT(kinetic_energy)) kinetic_energy = eip_kinetic_energy
         CPASSERT(.NOT. PRESENT(kinetic_energy))
      CASE (use_pwdft_force)
         CPASSERT(ASSOCIATED(force_env%pwdft_env))
         CPASSERT(.NOT. PRESENT(qs_env))
         CPASSERT(.NOT. PRESENT(fist_env))
         CPASSERT(.NOT. PRESENT(ipi_env))
         CALL pwdft_env_get(force_env%pwdft_env, energy=pwdft_energy)
         CALL pwdft_env_get(force_env%pwdft_env, cp_subsys=subsys)
         IF (PRESENT(potential_energy)) potential_energy = pwdft_energy%etotal
         CPASSERT(.NOT. PRESENT(kinetic_energy))
      CASE (use_qmmm)
         CALL qmmm_env_get(force_env%qmmm_env, &
                           subsys=subsys, &
                           potential_energy=potential_energy, &
                           kinetic_energy=kinetic_energy)
      CASE (use_qmmmx)
         CALL qmmmx_env_get(force_env%qmmmx_env, &
                            subsys=subsys, &
                            potential_energy=potential_energy, &
                            kinetic_energy=kinetic_energy)
      CASE (use_mixed_force)
         CPASSERT(ASSOCIATED(force_env%mixed_env))
         CPASSERT(.NOT. PRESENT(input))
         CALL get_mixed_env(force_env%mixed_env, &
                            mixed_energy=mixed_energy, &
                            subsys=subsys)
         IF (PRESENT(potential_energy)) potential_energy = mixed_energy%pot
         IF (PRESENT(kinetic_energy)) kinetic_energy = mixed_energy%kin
         ! In embedding we only have potential energies (electronic energies)
      CASE (use_embed)
         CPASSERT(ASSOCIATED(force_env%embed_env))
         CPASSERT(.NOT. PRESENT(input))
         CALL get_embed_env(force_env%embed_env, &
                            pot_energy=potential_energy, &
                            subsys=subsys)
      CASE (use_nnp_force)
         CPASSERT(ASSOCIATED(force_env%nnp_env))
         CPASSERT(.NOT. PRESENT(ipi_env))
         CALL nnp_env_get(force_env%nnp_env, &
                          nnp_potential_energy=potential_energy, &
                          subsys=subsys)
         CPASSERT(.NOT. PRESENT(kinetic_energy))
      CASE (use_ipi)
         CALL ipi_env_get(force_env%ipi_env, &
                          ipi_energy=potential_energy, &
                          subsys=subsys)
      CASE DEFAULT
         CPABORT("unknown in_use flag value ")
      END SELECT

      IF (PRESENT(force_env_section)) force_env_section => force_env%force_env_section
      IF (PRESENT(in_use)) in_use = force_env%in_use
      IF (PRESENT(method_name_id)) method_name_id = force_env%method_name_id
      IF (PRESENT(fist_env)) THEN
         fist_env => force_env%fist_env
      END IF
      IF (PRESENT(qs_env)) THEN
         qs_env => force_env%qs_env
      END IF
      IF (PRESENT(eip_env)) THEN
         eip_env => force_env%eip_env
      END IF
      IF (PRESENT(pwdft_env)) THEN
         pwdft_env => force_env%pwdft_env
      END IF
      IF (PRESENT(nnp_env)) THEN
         nnp_env => force_env%nnp_env
      END IF
      IF (PRESENT(ipi_env)) THEN
         ipi_env => force_env%ipi_env
      END IF
      IF (PRESENT(para_env)) para_env => force_env%para_env
      ! adjust the total energy for the metadynamics
      IF (ASSOCIATED(force_env%meta_env)) THEN
         IF (PRESENT(potential_energy)) THEN
            potential_energy = potential_energy + &
                               force_env%meta_env%epot_s + &
                               force_env%meta_env%epot_walls + &
                               force_env%meta_env%hills_env%energy
         END IF
         IF (PRESENT(kinetic_energy)) THEN
            kinetic_energy = kinetic_energy + force_env%meta_env%ekin_s
         END IF
      END IF
      ! adjust the total energy for the flexible partitioning
      IF (ASSOCIATED(force_env%fp_env) .AND. PRESENT(potential_energy)) THEN
         IF (force_env%fp_env%use_fp) THEN
            potential_energy = potential_energy + force_env%fp_env%energy
         END IF
      END IF
      IF (PRESENT(potential_energy)) THEN
         potential_energy = potential_energy + force_env%additional_potential
      END IF
      IF (PRESENT(additional_potential)) THEN
         additional_potential = force_env%additional_potential
      END IF
      IF (PRESENT(cell)) THEN
         CALL force_env_get(force_env, subsys=subsys_tmp)
         CALL cp_subsys_get(subsys_tmp, cell=cell)
      END IF
      IF (PRESENT(fp_env)) fp_env => force_env%fp_env
      IF (PRESENT(meta_env)) meta_env => force_env%meta_env
      IF (PRESENT(sub_force_env)) sub_force_env => force_env%sub_force_env
      IF (PRESENT(qmmm_env)) qmmm_env => force_env%qmmm_env
      IF (PRESENT(qmmmx_env)) qmmmx_env => force_env%qmmmx_env
      IF (PRESENT(mixed_env)) mixed_env => force_env%mixed_env
      IF (PRESENT(embed_env)) embed_env => force_env%embed_env
      IF (PRESENT(ipi_env)) ipi_env => force_env%ipi_env
      IF (PRESENT(globenv)) globenv => force_env%globenv
      IF (PRESENT(root_section)) root_section => force_env%root_section

   END SUBROUTINE force_env_get

! **************************************************************************************************
!> \brief returns the number of atoms
!> \param force_env the force_env you what information about
!> \return the number of atoms
!> \date   22.11.2010 updated (MK)
!> \author fawzi
! **************************************************************************************************
   FUNCTION force_env_get_natom(force_env) RESULT(n_atom)

      TYPE(force_env_type), INTENT(IN)                   :: force_env
      INTEGER                                            :: n_atom

      TYPE(cp_subsys_type), POINTER                      :: subsys

      n_atom = 0
      NULLIFY (subsys)
      CALL force_env_get(force_env, subsys=subsys)
      CALL cp_subsys_get(subsys, natom=n_atom)

   END FUNCTION force_env_get_natom

! **************************************************************************************************
!> \brief returns the number of particles in a force environment
!> \param force_env the force_env you what information about
!> \return the number of particles
!> \date   22.11.2010 (MK)
!> \author Matthias Krack
! **************************************************************************************************
   FUNCTION force_env_get_nparticle(force_env) RESULT(n_particle)

      TYPE(force_env_type), INTENT(IN)                   :: force_env
      INTEGER                                            :: n_particle

      TYPE(cp_subsys_type), POINTER                      :: subsys

      n_particle = 0
      NULLIFY (subsys)
      CALL force_env_get(force_env, subsys=subsys)
      CALL cp_subsys_get(subsys, nparticle=n_particle)

   END FUNCTION force_env_get_nparticle

! **************************************************************************************************
!> \brief returns the particle forces in a dimension(*) array
!> \param force_env the force_env you want to get the forces
!> \param frc the array of the forces
!> \param n ...
!> \date   22.11.2010 Creation
!> \author Matthias Krack
! **************************************************************************************************
   SUBROUTINE force_env_get_frc(force_env, frc, n)

      TYPE(force_env_type), INTENT(IN)                   :: force_env
      REAL(KIND=dp), DIMENSION(*), INTENT(OUT)           :: frc
      INTEGER, INTENT(IN)                                :: n

      CHARACTER(LEN=*), PARAMETER                        :: routineN = 'force_env_get_frc'

      INTEGER                                            :: handle
      TYPE(cp_subsys_type), POINTER                      :: subsys

      CALL timeset(routineN, handle)
      CPASSERT(force_env%ref_count > 0)
      CALL force_env_get(force_env, subsys=subsys)
      CALL pack_subsys_particles(subsys=subsys, f=frc(1:n))
      CALL timestop(handle)

   END SUBROUTINE force_env_get_frc

! **************************************************************************************************
!> \brief returns the particle positions in a dimension(*) array
!> \param force_env the force_env you want to get the positions
!> \param pos the array of the positions
!> \param n ...
!> \date   22.11.2010 updated (MK)
!> \author fawzi
! **************************************************************************************************
   SUBROUTINE force_env_get_pos(force_env, pos, n)

      TYPE(force_env_type), INTENT(IN)                   :: force_env
      REAL(kind=dp), DIMENSION(*), INTENT(OUT)           :: pos
      INTEGER, INTENT(IN)                                :: n

      CHARACTER(LEN=*), PARAMETER                        :: routineN = 'force_env_get_pos'

      INTEGER                                            :: handle
      TYPE(cp_subsys_type), POINTER                      :: subsys

      CALL timeset(routineN, handle)
      CPASSERT(force_env%ref_count > 0)
      CALL force_env_get(force_env, subsys=subsys)
      CALL pack_subsys_particles(subsys=subsys, r=pos(1:n))
      CALL timestop(handle)

   END SUBROUTINE force_env_get_pos

! **************************************************************************************************
!> \brief returns the particle velocities in a dimension(*) array
!> \param force_env the force_env you want to get the velocities
!> \param vel the array of the velocities
!> \param n ...
!> \date   22.11.2010 Creation (MK)
!> \author Matthias Krack
! **************************************************************************************************
   SUBROUTINE force_env_get_vel(force_env, vel, n)

      TYPE(force_env_type), INTENT(IN)                   :: force_env
      REAL(KIND=dp), DIMENSION(*), INTENT(OUT)           :: vel
      INTEGER, INTENT(IN)                                :: n

      CHARACTER(LEN=*), PARAMETER                        :: routineN = 'force_env_get_vel'

      INTEGER                                            :: handle
      TYPE(cp_subsys_type), POINTER                      :: subsys

      CALL timeset(routineN, handle)
      CPASSERT(force_env%ref_count > 0)
      CALL force_env_get(force_env, subsys=subsys)
      CALL pack_subsys_particles(subsys=subsys, v=vel(1:n))
      CALL timestop(handle)

   END SUBROUTINE force_env_get_vel

! **************************************************************************************************
!> \brief changes some attributes of the force_env
!> \param force_env the force environment where the cell should be changed
!> \param meta_env the new meta environment
!> \param fp_env ...
!> \param force_env_section ...
!> \param method_name_id ...
!> \param additional_potential ...
!> \par History
!>      09.2003 created [fawzi]
!> \author Fawzi Mohamed
! **************************************************************************************************
   SUBROUTINE force_env_set(force_env, meta_env, fp_env, force_env_section, &
                            method_name_id, additional_potential)

      TYPE(force_env_type), INTENT(INOUT)                :: force_env
      TYPE(meta_env_type), OPTIONAL, POINTER             :: meta_env
      TYPE(fp_type), OPTIONAL, POINTER                   :: fp_env
      TYPE(section_vals_type), OPTIONAL, POINTER         :: force_env_section
      INTEGER, OPTIONAL                                  :: method_name_id
      REAL(KIND=dp), INTENT(IN), OPTIONAL                :: additional_potential

      CPASSERT(force_env%ref_count > 0)
      IF (PRESENT(meta_env)) THEN
         IF (ASSOCIATED(force_env%meta_env)) THEN
            CALL meta_env_release(force_env%meta_env)
            DEALLOCATE (force_env%meta_env)
         END IF
         force_env%meta_env => meta_env
      END IF
      IF (PRESENT(fp_env)) THEN
         IF (ASSOCIATED(force_env%fp_env)) CALL fp_env_release(force_env%fp_env)
         force_env%fp_env => fp_env
      END IF
      IF (PRESENT(force_env_section)) THEN
         IF (ASSOCIATED(force_env_section)) THEN
            CALL section_vals_retain(force_env_section)
            CALL section_vals_release(force_env%force_env_section)
            force_env%force_env_section => force_env_section
         END IF
      END IF
      IF (PRESENT(additional_potential)) THEN
         force_env%additional_potential = additional_potential
      END IF
      IF (PRESENT(method_name_id)) THEN
         force_env%method_name_id = method_name_id
      END IF

   END SUBROUTINE force_env_set

! **************************************************************************************************
!> \brief returns the order of the multiple force_env
!> \param force_env_sections ...
!> \param root_section ...
!> \param i_force_eval ...
!> \param nforce_eval ...
!> \author teo
! **************************************************************************************************
   SUBROUTINE multiple_fe_list(force_env_sections, root_section, i_force_eval, nforce_eval)

      TYPE(section_vals_type), INTENT(IN)                :: force_env_sections, root_section
      INTEGER, DIMENSION(:), POINTER                     :: i_force_eval
      INTEGER                                            :: nforce_eval

      INTEGER                                            :: iforce_eval, main_force_eval
      INTEGER, DIMENSION(:), POINTER                     :: my_i_force_eval

! Let's treat the case of Multiple force_eval

      CALL section_vals_get(force_env_sections, n_repetition=nforce_eval)
      CALL section_vals_val_get(root_section, "MULTIPLE_FORCE_EVALS%FORCE_EVAL_ORDER", &
                                i_vals=my_i_force_eval)
      ALLOCATE (i_force_eval(nforce_eval))
      IF (nforce_eval > 0) THEN
         IF (nforce_eval == SIZE(my_i_force_eval)) THEN
            i_force_eval = my_i_force_eval
         ELSE
            ! The difference in the amount of defined force_env MUST be one..
            CPASSERT(nforce_eval - SIZE(my_i_force_eval) == 1)
            DO iforce_eval = 1, nforce_eval
               IF (ANY(my_i_force_eval == iforce_eval)) CYCLE
               main_force_eval = iforce_eval
               EXIT
            END DO
            i_force_eval(1) = main_force_eval
            i_force_eval(2:nforce_eval) = my_i_force_eval
         END IF
      END IF

   END SUBROUTINE multiple_fe_list

END MODULE force_env_types
