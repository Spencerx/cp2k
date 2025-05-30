!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Type for the canonical sampling through velocity rescaling
!> \author Teodoro Laino - 09.2007 University of Zurich [tlaino]
! **************************************************************************************************
MODULE csvr_system_types
   USE bibliography,                    ONLY: Bussi2007,&
                                              cite_reference
   USE extended_system_types,           ONLY: create_map_info_type,&
                                              map_info_type,&
                                              release_map_info_type
   USE input_section_types,             ONLY: section_vals_type,&
                                              section_vals_val_get
   USE kinds,                           ONLY: dp
   USE parallel_rng_types,              ONLY: GAUSSIAN,&
                                              next_rng_seed,&
                                              rng_stream_type
   USE simpar_types,                    ONLY: simpar_type
   USE string_utilities,                ONLY: compress
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE
   PUBLIC :: csvr_system_type, &
             csvr_init, &
             csvr_dealloc, &
             csvr_thermo_create

! **************************************************************************************************
   TYPE csvr_thermo_type
      INTEGER                                 :: degrees_of_freedom = 0
      REAL(KIND=dp)                           :: nkt = 0.0_dp
      REAL(KIND=dp)                           :: thermostat_energy = 0.0_dp
      REAL(KIND=dp)                           :: region_kin_energy = 0.0_dp
      TYPE(rng_stream_type)                   :: gaussian_rng_stream = rng_stream_type()
   END TYPE csvr_thermo_type

! **************************************************************************************************
   TYPE csvr_system_type
      INTEGER                                 :: region = 0, glob_num_csvr = 0, loc_num_csvr = 0
      REAL(KIND=dp)                           :: tau_csvr = 0.0_dp, dt_fact = 0.0_dp
      TYPE(csvr_thermo_type), POINTER         :: nvt(:) => NULL()
      TYPE(map_info_type), POINTER            :: map_info => NULL()
   END TYPE csvr_system_type

! *** Global parameters ***
   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'csvr_system_types'

CONTAINS

! **************************************************************************************************
!> \brief Initialize type for Canonical Sampling through Velocity Rescaling (CSVR)
!> \param csvr ...
!> \param simpar ...
!> \param section ...
!> \author Teodoro Laino [tlaino] 10.2007- University of Zurich
! **************************************************************************************************
   SUBROUTINE csvr_init(csvr, simpar, section)
      TYPE(csvr_system_type), POINTER                    :: csvr
      TYPE(simpar_type), POINTER                         :: simpar
      TYPE(section_vals_type), POINTER                   :: section

      NULLIFY (csvr%nvt)
      NULLIFY (csvr%map_info)
      csvr%loc_num_csvr = 0
      csvr%glob_num_csvr = 0
      csvr%dt_fact = 1.0_dp
      CALL cite_reference(Bussi2007)
      CALL section_vals_val_get(section, "TIMECON", r_val=csvr%tau_csvr)
      ! The CSVR library expects the tau_csv to be in unit of integration timestep
      ! if applied once.. divided by two if the process is applied both to the first
      ! and the second verlet step
      csvr%tau_csvr = csvr%tau_csvr/(0.5_dp*simpar%dt)
      CALL create_map_info_type(csvr%map_info)

   END SUBROUTINE csvr_init

! **************************************************************************************************
!> \brief Initialize NVT type for CSVR thermostat
!> \param csvr ...
!> \author Teodoro Laino [tlaino] 10.2007- University of Zurich
! **************************************************************************************************
   SUBROUTINE csvr_thermo_create(csvr)
      TYPE(csvr_system_type), POINTER                    :: csvr

      CHARACTER(LEN=40)                                  :: name
      INTEGER                                            :: i, ithermo, my_index
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:, :, :)     :: seed
      REAL(KIND=dp), DIMENSION(3, 2)                     :: initial_seed, my_seed

      CPASSERT(ASSOCIATED(csvr))
      CPASSERT(.NOT. ASSOCIATED(csvr%nvt))

      ALLOCATE (csvr%nvt(csvr%loc_num_csvr))
      DO i = 1, csvr%loc_num_csvr
         csvr%nvt(i)%thermostat_energy = 0.0_dp
      END DO
      ! Initialize the gaussian stream random number
      ALLOCATE (seed(3, 2, csvr%glob_num_csvr))
      initial_seed = next_rng_seed()

      seed(:, :, 1) = initial_seed
      DO ithermo = 2, csvr%glob_num_csvr
         seed(:, :, ithermo) = next_rng_seed(seed(:, :, ithermo - 1))
      END DO
      ! Update initial seed
      initial_seed = next_rng_seed(seed(:, :, csvr%glob_num_csvr))
      DO ithermo = 1, csvr%loc_num_csvr
         my_index = csvr%map_info%index(ithermo)
         my_seed = seed(:, :, my_index)
         WRITE (UNIT=name, FMT="(A,I8)") "Wiener process for Thermostat #", my_index
         CALL compress(name)
         csvr%nvt(ithermo)%gaussian_rng_stream = rng_stream_type( &
                                                 name=name, distribution_type=GAUSSIAN, extended_precision=.TRUE., seed=my_seed)
      END DO
      DEALLOCATE (seed)

   END SUBROUTINE csvr_thermo_create

! **************************************************************************************************
!> \brief Deallocate type for CSVR thermostat
!> \param csvr ...
!> \author Teodoro Laino [tlaino] 10.2007- University of Zurich
! **************************************************************************************************
   SUBROUTINE csvr_dealloc(csvr)
      TYPE(csvr_system_type), POINTER                    :: csvr

      IF (ASSOCIATED(csvr)) THEN
         CALL csvr_thermo_dealloc(csvr%nvt)
         CALL release_map_info_type(csvr%map_info)
         DEALLOCATE (csvr)
      END IF

   END SUBROUTINE csvr_dealloc

! **************************************************************************************************
!> \brief Deallocate NVT type for CSVR thermostat
!> \param nvt ...
!> \author Teodoro Laino [tlaino] 10.2007- University of Zurich
! **************************************************************************************************
   SUBROUTINE csvr_thermo_dealloc(nvt)
      TYPE(csvr_thermo_type), DIMENSION(:), POINTER      :: nvt

      IF (ASSOCIATED(nvt)) &
         DEALLOCATE (nvt)
   END SUBROUTINE csvr_thermo_dealloc

END MODULE csvr_system_types

