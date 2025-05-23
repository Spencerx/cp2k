!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Calculation of dispersion in DFTB
!> \author JGH
! **************************************************************************************************
MODULE qs_dftb_dispersion
   USE atomic_kind_types,               ONLY: atomic_kind_type,&
                                              get_atomic_kind_set
   USE atprop_types,                    ONLY: atprop_array_init,&
                                              atprop_type
   USE cp_control_types,                ONLY: dft_control_type,&
                                              dftb_control_type
   USE input_constants,                 ONLY: dispersion_d2,&
                                              dispersion_d3,&
                                              dispersion_d3bj,&
                                              dispersion_uff
   USE kinds,                           ONLY: dp
   USE message_passing,                 ONLY: mp_para_env_type
   USE particle_types,                  ONLY: particle_type
   USE qs_dftb_types,                   ONLY: qs_dftb_atom_type,&
                                              qs_dftb_pairpot_type
   USE qs_dftb_utils,                   ONLY: get_dftb_atom_param
   USE qs_dispersion_pairpot,           ONLY: calculate_dispersion_pairpot
   USE qs_dispersion_types,             ONLY: qs_dispersion_type
   USE qs_energy_types,                 ONLY: qs_energy_type
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_environment_type
   USE qs_force_types,                  ONLY: qs_force_type
   USE qs_kind_types,                   ONLY: get_qs_kind,&
                                              qs_kind_type
   USE qs_neighbor_list_types,          ONLY: get_iterator_info,&
                                              neighbor_list_iterate,&
                                              neighbor_list_iterator_create,&
                                              neighbor_list_iterator_p_type,&
                                              neighbor_list_iterator_release,&
                                              neighbor_list_set_p_type
   USE virial_methods,                  ONLY: virial_pair_force
   USE virial_types,                    ONLY: virial_type
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'qs_dftb_dispersion'

   PUBLIC :: calculate_dftb_dispersion

CONTAINS

! **************************************************************************************************
!> \brief ...
!> \param qs_env ...
!> \param para_env ...
!> \param calculate_forces ...
! **************************************************************************************************
   SUBROUTINE calculate_dftb_dispersion(qs_env, para_env, calculate_forces)

      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(mp_para_env_type), POINTER                    :: para_env
      LOGICAL, INTENT(IN)                                :: calculate_forces

      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(dftb_control_type), POINTER                   :: dftb_control
      TYPE(qs_dispersion_type), POINTER                  :: dispersion_env
      TYPE(qs_energy_type), POINTER                      :: energy

      CALL get_qs_env(qs_env=qs_env, &
                      energy=energy, &
                      dft_control=dft_control)

      energy%dispersion = 0._dp

      dftb_control => dft_control%qs_control%dftb_control
      IF (dftb_control%dispersion) THEN
         SELECT CASE (dftb_control%dispersion_type)
         CASE (dispersion_uff)
            CALL calculate_dispersion_uff(qs_env, para_env, calculate_forces)
         CASE (dispersion_d3, dispersion_d3bj, dispersion_d2)
            CALL get_qs_env(qs_env=qs_env, dispersion_env=dispersion_env)
            CALL calculate_dispersion_pairpot(qs_env, dispersion_env, &
                                              energy%dispersion, calculate_forces)
         CASE DEFAULT
            CPABORT("")
         END SELECT
      END IF

   END SUBROUTINE calculate_dftb_dispersion

! **************************************************************************************************
!> \brief ...
!> \param qs_env ...
!> \param para_env ...
!> \param calculate_forces ...
! **************************************************************************************************
   SUBROUTINE calculate_dispersion_uff(qs_env, para_env, calculate_forces)

      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(mp_para_env_type), POINTER                    :: para_env
      LOGICAL, INTENT(IN)                                :: calculate_forces

      CHARACTER(LEN=*), PARAMETER :: routineN = 'calculate_dispersion_uff'

      INTEGER                                            :: atom_a, atom_b, handle, iatom, ikind, &
                                                            jatom, jkind, nkind
      INTEGER, ALLOCATABLE, DIMENSION(:)                 :: atom_of_kind
      LOGICAL                                            :: use_virial
      LOGICAL, ALLOCATABLE, DIMENSION(:)                 :: define_kind
      REAL(dp), ALLOCATABLE, DIMENSION(:)                :: rc_kind
      REAL(KIND=dp)                                      :: a, b, c, devdw, dij, dr, eij, evdw, fac, &
                                                            rc, x0ij, xij, xp
      REAL(KIND=dp), DIMENSION(3)                        :: fdij, rij
      TYPE(atomic_kind_type), DIMENSION(:), POINTER      :: atomic_kind_set
      TYPE(atprop_type), POINTER                         :: atprop
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(dftb_control_type), POINTER                   :: dftb_control
      TYPE(neighbor_list_iterator_p_type), &
         DIMENSION(:), POINTER                           :: nl_iterator
      TYPE(neighbor_list_set_p_type), DIMENSION(:), &
         POINTER                                         :: sab_vdw
      TYPE(particle_type), DIMENSION(:), POINTER         :: particle_set
      TYPE(qs_dftb_atom_type), POINTER                   :: dftb_kind_a
      TYPE(qs_dftb_pairpot_type), DIMENSION(:, :), &
         POINTER                                         :: dftb_potential
      TYPE(qs_dftb_pairpot_type), POINTER                :: dftb_param_ij
      TYPE(qs_energy_type), POINTER                      :: energy
      TYPE(qs_force_type), DIMENSION(:), POINTER         :: force
      TYPE(qs_kind_type), DIMENSION(:), POINTER          :: qs_kind_set
      TYPE(virial_type), POINTER                         :: virial

      CALL timeset(routineN, handle)

      NULLIFY (atomic_kind_set, sab_vdw, atprop)

      CALL get_qs_env(qs_env=qs_env, &
                      energy=energy, &
                      atomic_kind_set=atomic_kind_set, &
                      qs_kind_set=qs_kind_set, &
                      virial=virial, atprop=atprop, &
                      dft_control=dft_control)

      energy%dispersion = 0._dp

      dftb_control => dft_control%qs_control%dftb_control

      IF (dftb_control%dispersion) THEN

         NULLIFY (dftb_potential)
         CALL get_qs_env(qs_env=qs_env, dftb_potential=dftb_potential)
         IF (calculate_forces) THEN
            NULLIFY (force, particle_set)
            CALL get_qs_env(qs_env=qs_env, &
                            particle_set=particle_set, &
                            force=force)
            CALL get_atomic_kind_set(atomic_kind_set=atomic_kind_set, atom_of_kind=atom_of_kind)
            use_virial = virial%pv_availability .AND. (.NOT. virial%pv_numer)
         ELSE
            use_virial = .FALSE.
         END IF
         nkind = SIZE(atomic_kind_set)
         ALLOCATE (define_kind(nkind), rc_kind(nkind))
         DO ikind = 1, nkind
            CALL get_qs_kind(qs_kind_set(ikind), dftb_parameter=dftb_kind_a)
            CALL get_dftb_atom_param(dftb_kind_a, defined=define_kind(ikind), rcdisp=rc_kind(ikind))
         END DO

         evdw = 0._dp

         IF (atprop%energy) THEN
            CALL get_qs_env(qs_env=qs_env, particle_set=particle_set)
            CALL atprop_array_init(atprop%atevdw, natom=SIZE(particle_set))
         END IF

         CALL get_qs_env(qs_env=qs_env, sab_vdw=sab_vdw)
         CALL neighbor_list_iterator_create(nl_iterator, sab_vdw)
         DO WHILE (neighbor_list_iterate(nl_iterator) == 0)
            CALL get_iterator_info(nl_iterator, ikind=ikind, jkind=jkind, iatom=iatom, jatom=jatom, r=rij)
            IF ((.NOT. define_kind(ikind)) .OR. (.NOT. define_kind(jkind))) CYCLE
            rc = rc_kind(ikind) + rc_kind(jkind)
            ! vdW potential
            dr = SQRT(SUM(rij(:)**2))
            IF (dr <= rc .AND. dr > 0.001_dp) THEN
               fac = 1._dp
               IF (iatom == jatom) fac = 0.5_dp
               ! retrieve information on potential
               dftb_param_ij => dftb_potential(ikind, jkind)
               ! vdW parameter
               xij = dftb_param_ij%xij
               dij = dftb_param_ij%dij
               x0ij = dftb_param_ij%x0ij
               a = dftb_param_ij%a
               b = dftb_param_ij%b
               c = dftb_param_ij%c
               IF (dr > x0ij) THEN
                  ! This is the standard London contribution.
                  ! UFF1 - Eq. 20 (long-range)
                  xp = xij/dr
                  eij = dij*(-2._dp*xp**6 + xp**12)*fac
                  evdw = evdw + eij
                  IF (calculate_forces .AND. (dr > 0.001_dp)) THEN
                     devdw = dij*12._dp*(xp**6 - xp**12)/dr*fac
                     atom_a = atom_of_kind(iatom)
                     atom_b = atom_of_kind(jatom)
                     fdij(:) = devdw*rij(:)/dr
                     force(ikind)%dispersion(:, atom_a) = &
                        force(ikind)%dispersion(:, atom_a) - fdij(:)
                     force(jkind)%dispersion(:, atom_b) = &
                        force(jkind)%dispersion(:, atom_b) + fdij(:)
                  END IF
               ELSE
                  ! Shorter distance.
                  ! London contribution should converge to a finite value.
                  ! Using a parabola of the form (y = A - Bx**5 -Cx**10).
                  ! Analytic parameters by forcing energy, first and second
                  ! derivatives to be continuous.
                  eij = (A - B*dr**5 - C*dr**10)*fac
                  evdw = evdw + eij
                  IF (calculate_forces .AND. (dr > 0.001_dp)) THEN
                     atom_a = atom_of_kind(iatom)
                     atom_b = atom_of_kind(jatom)
                     devdw = (-5*B*dr**4 - 10*C*dr**9)*fac
                     fdij(:) = devdw*rij(:)/dr
                     force(ikind)%dispersion(:, atom_a) = &
                        force(ikind)%dispersion(:, atom_a) - fdij(:)
                     force(jkind)%dispersion(:, atom_b) = &
                        force(jkind)%dispersion(:, atom_b) + fdij(:)
                  END IF
               END IF
               IF (atprop%energy) THEN
                  atprop%atevdw(iatom) = atprop%atevdw(iatom) + 0.5_dp*eij
                  atprop%atevdw(jatom) = atprop%atevdw(jatom) + 0.5_dp*eij
               END IF
               IF (calculate_forces .AND. (dr > 0.001_dp) .AND. use_virial) THEN
                  CALL virial_pair_force(virial%pv_virial, -1._dp, fdij, rij)
               END IF
            END IF
         END DO
         CALL neighbor_list_iterator_release(nl_iterator)

         ! set dispersion energy
         CALL para_env%sum(evdw)
         energy%dispersion = evdw

      END IF

      CALL timestop(handle)

   END SUBROUTINE calculate_dispersion_uff

END MODULE qs_dftb_dispersion

