!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \author MI (12.01.2007)
! **************************************************************************************************
MODULE shell_potential_types

   USE kinds,                           ONLY: default_string_length,&
                                              dp
#include "../base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

! Global parameters (only in this module)

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'shell_potential_types'

! **************************************************************************************************
!> \brief Define the shell type
! **************************************************************************************************
   TYPE shell_kind_type
      REAL(dp)                               :: charge_core = 0.0_dp, &
                                                charge_shell = 0.0_dp
      REAL(dp)                               :: mass_core = 0.0_dp, &
                                                massfrac = 0.0_dp, &
                                                mass_shell = 0.0_dp
      REAL(dp)                               :: k2_spring = 0.0_dp, k4_spring = 0.0_dp
      REAL(dp)                               :: max_dist = 0.0_dp
      REAL(dp)                               :: shell_cutoff = 0.0_dp
   END TYPE shell_kind_type

! **************************************************************************************************
   TYPE shell_p_type
      CHARACTER(LEN=default_string_length)   :: atm_name = ""
      TYPE(shell_kind_type), POINTER          :: shell => NULL()
   END TYPE shell_p_type

! Public subroutines

   PUBLIC :: get_shell, shell_p_create, &
             shell_p_release

! Public data types

   PUBLIC :: shell_p_type, shell_kind_type

CONTAINS

! **************************************************************************************************
!> \brief ...
!> \param shell ...
!> \param charge ...
!> \param charge_core ...
!> \param charge_shell ...
!> \param mass_core ...
!> \param mass_shell ...
!> \param k2_spring ...
!> \param k4_spring ...
!> \param max_dist ...
!> \param shell_cutoff ...
! **************************************************************************************************
   ELEMENTAL SUBROUTINE get_shell(shell, charge, charge_core, charge_shell, mass_core, &
                                  mass_shell, k2_spring, k4_spring, max_dist, shell_cutoff)

      TYPE(shell_kind_type), INTENT(IN)                  :: shell
      REAL(KIND=dp), INTENT(OUT), OPTIONAL               :: charge, charge_core, charge_shell, &
                                                            mass_core, mass_shell, k2_spring, &
                                                            k4_spring, max_dist, shell_cutoff

      IF (PRESENT(charge)) charge = shell%charge_core + shell%charge_shell
      IF (PRESENT(charge_core)) charge_core = shell%charge_core
      IF (PRESENT(charge_shell)) charge_shell = shell%charge_shell
      IF (PRESENT(mass_core)) mass_core = shell%mass_core
      IF (PRESENT(mass_shell)) mass_shell = shell%mass_shell
      IF (PRESENT(k2_spring)) k2_spring = shell%k2_spring
      IF (PRESENT(k4_spring)) k4_spring = shell%k4_spring
      IF (PRESENT(max_dist)) max_dist = shell%max_dist
      IF (PRESENT(shell_cutoff)) shell_cutoff = shell%shell_cutoff

   END SUBROUTINE

! **************************************************************************************************
!> \brief ...
!> \param shell_list ...
!> \param ndim ...
! **************************************************************************************************
   SUBROUTINE shell_p_create(shell_list, ndim)

      TYPE(shell_p_type), DIMENSION(:), POINTER          :: shell_list
      INTEGER, INTENT(IN)                                :: ndim

      INTEGER                                            :: i

      CPASSERT(.NOT. ASSOCIATED(shell_list))
      ALLOCATE (shell_list(ndim))

      DO i = 1, ndim
         ALLOCATE (shell_list(i)%shell)
      END DO

   END SUBROUTINE shell_p_create

! **************************************************************************************************
!> \brief ...
!> \param shell_list ...
! **************************************************************************************************
   SUBROUTINE shell_p_release(shell_list)
      TYPE(shell_p_type), DIMENSION(:), POINTER          :: shell_list

      INTEGER                                            :: i

      IF (ASSOCIATED(shell_list)) THEN
         DO i = 1, SIZE(shell_list)
            DEALLOCATE (shell_list(i)%shell)
         END DO
         DEALLOCATE (shell_list)
      END IF

      NULLIFY (shell_list)

   END SUBROUTINE shell_p_release

END MODULE shell_potential_types
