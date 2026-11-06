/**************************************************************************/
/*  libgodot_compositor_services_controller.mm                            */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#import "libgodot_compositor_services_controller.h"

#import "rendering_native_surface_compositor_services.h"

#include "modules/modules_enabled.gen.h"

#if defined(VISIONOS_ENABLED) && defined(MODULE_VISIONOS_XR_ENABLED)
#define COMPOSITOR_SERVICES_AVAILABLE
#endif

#ifdef COMPOSITOR_SERVICES_AVAILABLE
#import "platform/visionos/godot_compositor_services_renderer.h"

#include "modules/visionos_xr/visionos_xr_interface.h"
#endif

void LibgodotCompositorServicesController::_bind_methods() {
	ClassDB::bind_static_method(get_class_static(), D_METHOD("create"), &LibgodotCompositorServicesController::create);
	ClassDB::bind_method(D_METHOD("get_main_window_surface"), &LibgodotCompositorServicesController::get_main_window_surface);
	ClassDB::bind_method(D_METHOD("begin_session", "layer_renderer", "minimum_near_plane_distance"), &LibgodotCompositorServicesController::begin_session);
	ClassDB::bind_method(D_METHOD("run_render_loop"), &LibgodotCompositorServicesController::run_render_loop);
	ClassDB::bind_method(D_METHOD("end_session"), &LibgodotCompositorServicesController::end_session);
	ClassDB::bind_method(D_METHOD("world_recentered"), &LibgodotCompositorServicesController::world_recentered);
	ClassDB::bind_method(D_METHOD("is_presenting_frames"), &LibgodotCompositorServicesController::is_presenting_frames);
	ClassDB::bind_method(D_METHOD("submit_spatial_event", "phase", "chirality", "hand_pose", "has_selection_ray", "selection_ray_origin", "selection_ray_direction"), &LibgodotCompositorServicesController::submit_spatial_event);

	BIND_ENUM_CONSTANT(SPATIAL_EVENT_PHASE_UNKNOWN);
	BIND_ENUM_CONSTANT(SPATIAL_EVENT_PHASE_ACTIVE);
	BIND_ENUM_CONSTANT(SPATIAL_EVENT_PHASE_CANCELLED);
	BIND_ENUM_CONSTANT(SPATIAL_EVENT_PHASE_ENDED);

	BIND_ENUM_CONSTANT(SPATIAL_EVENT_CHIRALITY_NONE);
	BIND_ENUM_CONSTANT(SPATIAL_EVENT_CHIRALITY_LEFT);
	BIND_ENUM_CONSTANT(SPATIAL_EVENT_CHIRALITY_RIGHT);
}

Ref<RenderingNativeSurface> LibgodotCompositorServicesController::get_main_window_surface() const {
	return main_window_surface;
}

#ifdef COMPOSITOR_SERVICES_AVAILABLE

static cp_layer_renderer_t layer_renderer_at(uint64_t p_address) {
	return (__bridge cp_layer_renderer_t)(void *)p_address;
}

static GDTCompositorServicesRenderer *session_at(void *p_address) {
	return (__bridge GDTCompositorServicesRenderer *)p_address;
}

Ref<LibgodotCompositorServicesController> LibgodotCompositorServicesController::create() {
	Ref<RenderingNativeSurfaceCompositorServices> surface;
	surface.instantiate();

	Ref<LibgodotCompositorServicesController> controller;
	controller.instantiate();
	controller->main_window_surface = surface;
	return controller;
}

void LibgodotCompositorServicesController::begin_session(uint64_t p_layer_renderer, float p_minimum_near_plane_distance) {
	ERR_FAIL_COND_MSG(![NSThread isMainThread], "begin_session() must be called on the main thread.");
	ERR_FAIL_COND_MSG(active_session != nullptr, "An immersive session is already running on this controller.");
	ERR_FAIL_COND(p_layer_renderer == 0);

	GDTCompositorServicesRenderer *session = [[GDTCompositorServicesRenderer alloc] initWithLayerRenderer:layer_renderer_at(p_layer_renderer)
																				 minimumNearPlaneDistance:p_minimum_near_plane_distance];
	[session updateXRInterface];
	active_session = (void *)CFBridgingRetain(session);
}

void LibgodotCompositorServicesController::run_render_loop() {
	ERR_FAIL_COND_MSG([NSThread isMainThread], "run_render_loop() blocks until the session ends; call it from a dedicated thread.");
	ERR_FAIL_NULL_MSG(active_session, "Call begin_session() before run_render_loop().");

	GDTCompositorServicesRenderer *session = session_at(active_session);
	[session startRenderLoop];

	dispatch_sync(dispatch_get_main_queue(), ^{
		[session detachFromXRInterface];
		CFBridgingRelease(active_session);
		active_session = nullptr;
	});
}

void LibgodotCompositorServicesController::end_session() {
	ERR_FAIL_COND_MSG(![NSThread isMainThread], "end_session() must be called on the main thread.");
	if (active_session == nullptr) {
		return;
	}
	session_at(active_session).stopRequested = YES;
}

void LibgodotCompositorServicesController::world_recentered() {
	ERR_FAIL_COND_MSG(![NSThread isMainThread], "world_recentered() must be called on the main thread.");
	if (active_session == nullptr) {
		return;
	}
	[session_at(active_session) worldRecentered];
}

bool LibgodotCompositorServicesController::is_presenting_frames() const {
	ERR_FAIL_COND_V_MSG(![NSThread isMainThread], false, "is_presenting_frames() must be called on the main thread.");
	if (active_session == nullptr) {
		return false;
	}
	return session_at(active_session).isPresentingFrames;
}

static_assert((int)LibgodotCompositorServicesController::SPATIAL_EVENT_PHASE_ACTIVE == (int)VisionOSSpatialEvent::Phase::active);
static_assert((int)LibgodotCompositorServicesController::SPATIAL_EVENT_PHASE_ENDED == (int)VisionOSSpatialEvent::Phase::ended);
static_assert((int)LibgodotCompositorServicesController::SPATIAL_EVENT_CHIRALITY_RIGHT == (int)VisionOSSpatialEvent::Chirality::right);

void LibgodotCompositorServicesController::submit_spatial_event(SpatialEventPhase p_phase, SpatialEventChirality p_chirality, const Transform3D &p_hand_pose, bool p_has_selection_ray, const Vector3 &p_selection_ray_origin, const Vector3 &p_selection_ray_direction) {
	ERR_FAIL_COND_MSG(![NSThread isMainThread], "submit_spatial_event() must be called on the main thread.");
	Ref<VisionOSXRInterface> visionos_xr_interface = VisionOSXRInterface::find_interface();
	if (active_session == nullptr || visionos_xr_interface.is_null()) {
		return;
	}

	VisionOSSpatialEvent event;
	event.phase = (VisionOSSpatialEvent::Phase)p_phase;
	event.chirality = (VisionOSSpatialEvent::Chirality)p_chirality;
	event.hand_pose = p_hand_pose;
	event.has_ray = p_has_selection_ray;
	if (p_has_selection_ray) {
		event.ray.set_look_at(p_selection_ray_origin, p_selection_ray_origin + p_selection_ray_direction);
	}
	visionos_xr_interface->on_spatial_event(event);
}

LibgodotCompositorServicesController::~LibgodotCompositorServicesController() {
	ERR_FAIL_COND_MSG(active_session != nullptr, "The controller was released while an immersive session was still running.");
}

#else

Ref<LibgodotCompositorServicesController> LibgodotCompositorServicesController::create() {
	ERR_FAIL_V_MSG(Ref<LibgodotCompositorServicesController>(), "LibgodotCompositorServicesController requires a visionOS build with the visionos_xr module.");
}

void LibgodotCompositorServicesController::begin_session(uint64_t, float) {
}

void LibgodotCompositorServicesController::run_render_loop() {
}

void LibgodotCompositorServicesController::end_session() {
}

void LibgodotCompositorServicesController::world_recentered() {
}

bool LibgodotCompositorServicesController::is_presenting_frames() const {
	return false;
}

void LibgodotCompositorServicesController::submit_spatial_event(SpatialEventPhase, SpatialEventChirality, const Transform3D &, bool, const Vector3 &, const Vector3 &) {
}

LibgodotCompositorServicesController::~LibgodotCompositorServicesController() {
}

#endif
