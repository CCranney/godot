/**************************************************************************/
/*  rendering_native_surface_compositor_services.mm                       */
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

#import "rendering_native_surface_compositor_services.h"

#include "modules/modules_enabled.gen.h"

#if defined(VISIONOS_ENABLED) && defined(MODULE_VISIONOS_XR_ENABLED)
#define COMPOSITOR_SERVICES_AVAILABLE
#endif

#ifdef COMPOSITOR_SERVICES_AVAILABLE
#include "drivers/metal/rendering_context_driver_metal.h"
#import "platform/visionos/godot_app_delegate_service_visionos.h"
#import "platform/visionos/godot_compositor_services_renderer.h"

#import <CompositorServices/CompositorServices.h>
#endif

void RenderingNativeSurfaceCompositorServices::_bind_methods() {
	ClassDB::bind_static_method(get_class_static(), D_METHOD("create", "layer_renderer"), &RenderingNativeSurfaceCompositorServices::create_api);
	ClassDB::bind_method(D_METHOD("begin_session", "layer_renderer", "minimum_near_plane_distance"), &RenderingNativeSurfaceCompositorServices::begin_session);
	ClassDB::bind_method(D_METHOD("run_render_loop"), &RenderingNativeSurfaceCompositorServices::run_render_loop);
	ClassDB::bind_method(D_METHOD("end_session"), &RenderingNativeSurfaceCompositorServices::end_session);
	ClassDB::bind_method(D_METHOD("world_recentered"), &RenderingNativeSurfaceCompositorServices::world_recentered);
}

#ifdef COMPOSITOR_SERVICES_AVAILABLE

static cp_layer_renderer_t layer_renderer_at(uint64_t p_address) {
	return (__bridge cp_layer_renderer_t)(void *)p_address;
}

static GDTCompositorServicesRenderer *session_at(void *p_address) {
	return (__bridge GDTCompositorServicesRenderer *)p_address;
}

Ref<RenderingNativeSurfaceCompositorServices> RenderingNativeSurfaceCompositorServices::create_api(uint64_t p_layer_renderer) {
	ERR_FAIL_COND_V(p_layer_renderer == 0, Ref<RenderingNativeSurfaceCompositorServices>());

	id<MTLDevice> device = cp_layer_renderer_get_device(layer_renderer_at(p_layer_renderer));
	ERR_FAIL_NULL_V_MSG(device, Ref<RenderingNativeSurfaceCompositorServices>(), "The layer renderer has no Metal device.");

	[GDTAppDelegateServiceVisionOS setRenderMode:GDTRenderModeCompositorServices];

	Ref<RenderingNativeSurfaceCompositorServices> surface;
	surface.instantiate();
	surface->metal_device = ((MTL::Device *)(__bridge void *)device)->retain();
	return surface;
}

RenderingContextDriver *RenderingNativeSurfaceCompositorServices::create_rendering_context(const String &p_driver_name) {
	ERR_FAIL_COND_V_MSG(p_driver_name != "metal", nullptr, "Compositor Services surfaces only support the Metal rendering driver.");
	return memnew(RenderingContextDriverMetal(metal_device));
}

void RenderingNativeSurfaceCompositorServices::begin_session(uint64_t p_layer_renderer, float p_minimum_near_plane_distance) {
	ERR_FAIL_COND_MSG(![NSThread isMainThread], "begin_session() must be called on the main thread.");
	ERR_FAIL_COND_MSG(active_session != nullptr, "An immersive session is already running on this surface.");
	ERR_FAIL_COND(p_layer_renderer == 0);

	GDTCompositorServicesRenderer *session = [[GDTCompositorServicesRenderer alloc] initWithLayerRenderer:layer_renderer_at(p_layer_renderer)
																				 minimumNearPlaneDistance:p_minimum_near_plane_distance];
	[session updateXRInterface];
	active_session = (void *)CFBridgingRetain(session);
}

void RenderingNativeSurfaceCompositorServices::run_render_loop() {
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

void RenderingNativeSurfaceCompositorServices::end_session() {
	ERR_FAIL_COND_MSG(![NSThread isMainThread], "end_session() must be called on the main thread.");
	if (active_session == nullptr) {
		return;
	}
	session_at(active_session).stopRequested = YES;
}

void RenderingNativeSurfaceCompositorServices::world_recentered() {
	ERR_FAIL_COND_MSG(![NSThread isMainThread], "world_recentered() must be called on the main thread.");
	if (active_session == nullptr) {
		return;
	}
	[session_at(active_session) worldRecentered];
}

RenderingNativeSurfaceCompositorServices::~RenderingNativeSurfaceCompositorServices() {
	if (metal_device) {
		metal_device->release();
	}
}

#else

Ref<RenderingNativeSurfaceCompositorServices> RenderingNativeSurfaceCompositorServices::create_api(uint64_t) {
	ERR_FAIL_V_MSG(Ref<RenderingNativeSurfaceCompositorServices>(), "Compositor Services surfaces require a visionOS build with the visionos_xr module.");
}

RenderingContextDriver *RenderingNativeSurfaceCompositorServices::create_rendering_context(const String &) {
	return nullptr;
}

void RenderingNativeSurfaceCompositorServices::begin_session(uint64_t, float) {
	ERR_FAIL_MSG("Compositor Services surfaces require a visionOS build with the visionos_xr module.");
}

void RenderingNativeSurfaceCompositorServices::run_render_loop() {
}

void RenderingNativeSurfaceCompositorServices::end_session() {
}

void RenderingNativeSurfaceCompositorServices::world_recentered() {
}

RenderingNativeSurfaceCompositorServices::~RenderingNativeSurfaceCompositorServices() {
}

#endif
