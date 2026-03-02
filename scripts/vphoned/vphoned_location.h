/*
 * vphoned_location — CoreLocation simulation via CLSimulationManager.
 *
 * Uses private CLSimulationManager API to inject simulated GPS coordinates
 * into the guest. Probes available selectors at runtime since the API
 * varies across iOS versions.
 */

#pragma once
#import <Foundation/Foundation.h>

/// Load CoreLocation and probe CLSimulationManager selectors. Returns NO on failure.
BOOL vp_location_load(void);

/// Whether location simulation is available (load succeeded).
BOOL vp_location_available(void);

/// Simulate a GPS location update.
void vp_location_simulate(double lat, double lon, double alt,
                           double hacc, double vacc,
                           double speed, double course);

/// Clear simulated location.
void vp_location_clear(void);
