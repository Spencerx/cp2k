!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Utility functions that are needed for RTP/EMD in combination with
!>        HF or hybrid functionals (needs to deal with imaginary KS and P
!> \par History
!>      2014 created [fschiff]
!> \author Florina Schiffmann
! **************************************************************************************************
MODULE rt_hfx_utils
   USE admm_types,                      ONLY: get_admm_env,&
                                              set_admm_env
   USE cp_control_types,                ONLY: dft_control_type
   USE cp_dbcsr_api,                    ONLY: dbcsr_create,&
                                              dbcsr_p_type,&
                                              dbcsr_set,&
                                              dbcsr_type_antisymmetric
   USE cp_dbcsr_cp2k_link,              ONLY: cp_dbcsr_alloc_block_from_nbl
   USE cp_dbcsr_operations,             ONLY: dbcsr_allocate_matrix_set,&
                                              dbcsr_deallocate_matrix_set
   USE kinds,                           ONLY: dp
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_environment_type
   USE qs_neighbor_list_types,          ONLY: neighbor_list_set_p_type
   USE qs_rho_types,                    ONLY: qs_rho_get,&
                                              qs_rho_set,&
                                              qs_rho_type
#include "../base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'rt_hfx_utils'

   PUBLIC :: rtp_hfx_rebuild

!***
CONTAINS
! **************************************************************************************************
!> \brief rebuilds the structures of P and KS (imaginary) in case S changed
!> \param qs_env ...
!> \author Florian Schiffmann
! **************************************************************************************************
   SUBROUTINE rtp_hfx_rebuild(qs_env)
      TYPE(qs_environment_type), POINTER                 :: qs_env

      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: matrix_ks_aux_im, matrix_s_aux, &
                                                            rho_aux_ao_im
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(neighbor_list_set_p_type), DIMENSION(:), &
         POINTER                                         :: sab_aux
      TYPE(qs_rho_type), POINTER                         :: rho_aux

      NULLIFY (dft_control)
      NULLIFY (sab_aux, rho_aux, rho_aux_ao_im, matrix_ks_aux_im, matrix_s_aux)

      CALL get_qs_env(qs_env, &
                      dft_control=dft_control)

      IF (dft_control%do_admm) THEN
         CALL get_admm_env(qs_env%admm_env, &
                           matrix_s_aux_fit=matrix_s_aux, &
                           sab_aux_fit=sab_aux, &
                           rho_aux_fit=rho_aux, &
                           matrix_ks_aux_fit_im=matrix_ks_aux_im)
         CALL qs_rho_get(rho_aux, rho_ao_im=rho_aux_ao_im)
         CALL rebuild_matrices(rho_aux_ao_im, matrix_ks_aux_im, sab_aux, matrix_s_aux, &
                               dft_control%nspins)
         CALL set_admm_env(qs_env%admm_env, matrix_ks_aux_fit_im=matrix_ks_aux_im)
         CALL qs_rho_set(rho_aux, rho_ao_im=rho_aux_ao_im)
      END IF

   END SUBROUTINE rtp_hfx_rebuild

! **************************************************************************************************
!> \brief does the actual rebuilding of P and KS (imaginary) in case S changed
!> \param matrix_p ...
!> \param matrix_ks ...
!> \param sab_orb ...
!> \param matrix_s ...
!> \param nspins ...
!> \author Florian Schiffmann
! **************************************************************************************************

   SUBROUTINE rebuild_matrices(matrix_p, matrix_ks, sab_orb, matrix_s, nspins)
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: matrix_p, matrix_ks
      TYPE(neighbor_list_set_p_type), DIMENSION(:), &
         POINTER                                         :: sab_orb
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: matrix_s
      INTEGER, INTENT(in)                                :: nspins

      INTEGER                                            :: i

      IF (ASSOCIATED(matrix_p)) THEN
         CALL dbcsr_deallocate_matrix_set(matrix_p)
      END IF
      ! Create a new density matrix set
      CALL dbcsr_allocate_matrix_set(matrix_p, nspins)
      DO i = 1, nspins
         ALLOCATE (matrix_p(i)%matrix)
         CALL dbcsr_create(matrix=matrix_p(i)%matrix, template=matrix_s(1)%matrix, &
                           name="Imaginary density matrix", matrix_type=dbcsr_type_antisymmetric)
         CALL cp_dbcsr_alloc_block_from_nbl(matrix_p(i)%matrix, sab_orb)
         CALL dbcsr_set(matrix_p(i)%matrix, 0.0_dp)
      END DO

      IF (ASSOCIATED(matrix_ks)) THEN
         CALL dbcsr_deallocate_matrix_set(matrix_ks)
      END IF
      ! Create a new density matrix set
      CALL dbcsr_allocate_matrix_set(matrix_ks, nspins)
      DO i = 1, nspins
         ALLOCATE (matrix_ks(i)%matrix)
         CALL dbcsr_create(matrix=matrix_ks(i)%matrix, template=matrix_s(1)%matrix, &
                           name="Imaginary Kohn-Sham matrix", matrix_type=dbcsr_type_antisymmetric)
         CALL cp_dbcsr_alloc_block_from_nbl(matrix_ks(i)%matrix, sab_orb)
         CALL dbcsr_set(matrix_ks(i)%matrix, 0.0_dp)
      END DO

   END SUBROUTINE rebuild_matrices

END MODULE rt_hfx_utils
