/**************************************************************************/
/*  libgodot_compositor_services_controller.h                             */
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

#pragma once

#include "core/math/transform_3d.h"
#include "core/math/vector3.h"
#include "core/object/class_db.h"
#include "core/object/ref_counted.h"
#include "servers/rendering/rendering_native_surface.h"

class LibgodotCompositorServicesController : public RefCounted {
	GDCLASS(LibgodotCompositorServicesController, RefCounted);

public:
	enum SpatialEventPhase {
		SPATIAL_EVENT_PHASE_UNKNOWN,
		SPATIAL_EVENT_PHASE_ACTIVE,
		SPATIAL_EVENT_PHASE_CANCELLED,
		SPATIAL_EVENT_PHASE_ENDED,
	};

	enum SpatialEventChirality {
		SPATIAL_EVENT_CHIRALITY_NONE,
		SPATIAL_EVENT_CHIRALITY_LEFT,
		SPATIAL_EVENT_CHIRALITY_RIGHT,
	};

private:
	Ref<RenderingNativeSurface> main_window_surface;
	void *active_session = nullptr;

protected:
	static void _bind_methods();

public:
	static Ref<LibgodotCompositorServicesController> create();

	Ref<RenderingNativeSurface> get_main_window_surface() const;

	void begin_session(uint64_t p_layer_renderer, float p_minimum_near_plane_distance);
	void run_render_loop();
	void end_session();
	void world_recentered();

	void submit_spatial_event(SpatialEventPhase p_phase, SpatialEventChirality p_chirality, const Transform3D &p_hand_pose, bool p_has_selection_ray, const Vector3 &p_selection_ray_origin, const Vector3 &p_selection_ray_direction);

	bool is_presenting_frames() const;

	~LibgodotCompositorServicesController();
};

VARIANT_ENUM_CAST(LibgodotCompositorServicesController::SpatialEventPhase);
VARIANT_ENUM_CAST(LibgodotCompositorServicesController::SpatialEventChirality);
