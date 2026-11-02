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

#import <CompositorServices/CompositorServices.h>
#import <Metal/Metal.h>
#endif

void LibgodotCompositorServicesController::_bind_methods() {
	ClassDB::bind_static_method(get_class_static(), D_METHOD("create"), &LibgodotCompositorServicesController::create);
	ClassDB::bind_method(D_METHOD("get_main_window_surface"), &LibgodotCompositorServicesController::get_main_window_surface);
	ClassDB::bind_method(D_METHOD("begin_session", "layer_renderer", "minimum_near_plane_distance"), &LibgodotCompositorServicesController::begin_session);
	ClassDB::bind_method(D_METHOD("run_render_loop"), &LibgodotCompositorServicesController::run_render_loop);
	ClassDB::bind_method(D_METHOD("end_session"), &LibgodotCompositorServicesController::end_session);
	ClassDB::bind_method(D_METHOD("world_recentered"), &LibgodotCompositorServicesController::world_recentered);
	ClassDB::bind_method(D_METHOD("is_session_active"), &LibgodotCompositorServicesController::is_session_active);
	ClassDB::bind_method(D_METHOD("is_presenting_frames"), &LibgodotCompositorServicesController::is_presenting_frames);
}

Ref<RenderingNativeSurface> LibgodotCompositorServicesController::get_main_window_surface() const {
	return main_window_surface;
}

bool LibgodotCompositorServicesController::is_session_active() const {
	return active_session != nullptr;
}

#ifdef COMPOSITOR_SERVICES_AVAILABLE

static cp_layer_renderer_t layer_renderer_at(uint64_t p_address) {
	return (__bridge cp_layer_renderer_t)(void *)p_address;
}

static GDTCompositorServicesRenderer *session_at(void *p_address) {
	return (__bridge GDTCompositorServicesRenderer *)p_address;
}

static void warn_if_layer_renderer_uses_another_device(cp_layer_renderer_t p_layer_renderer) {
	id<MTLDevice> layer_renderer_device = cp_layer_renderer_get_device(p_layer_renderer);
	id<MTLDevice> engine_device = MTLCreateSystemDefaultDevice();
	if (layer_renderer_device != engine_device) {
		WARN_PRINT("The layer renderer's Metal device differs from the engine's system default device; its drawables may not be usable by the engine.");
	}
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

	cp_layer_renderer_t layer_renderer = layer_renderer_at(p_layer_renderer);
	warn_if_layer_renderer_uses_another_device(layer_renderer);

	GDTCompositorServicesRenderer *session = [[GDTCompositorServicesRenderer alloc] initWithLayerRenderer:layer_renderer
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

LibgodotCompositorServicesController::~LibgodotCompositorServicesController() {
	ERR_FAIL_COND_MSG(active_session != nullptr, "The controller was released while an immersive session was still running.");
}

#else

static const char *compositor_services_unavailable_message = "LibgodotCompositorServicesController requires a visionOS build with the visionos_xr module.";

Ref<LibgodotCompositorServicesController> LibgodotCompositorServicesController::create() {
	ERR_FAIL_V_MSG(Ref<LibgodotCompositorServicesController>(), compositor_services_unavailable_message);
}

void LibgodotCompositorServicesController::begin_session(uint64_t, float) {
	ERR_FAIL_MSG(compositor_services_unavailable_message);
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

LibgodotCompositorServicesController::~LibgodotCompositorServicesController() {
}

#endif
