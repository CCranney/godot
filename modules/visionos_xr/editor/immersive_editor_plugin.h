/**************************************************************************/
/*  immersive_editor_plugin.h                                             */
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

#include "core/templates/hash_map.h"
#include "core/templates/local_vector.h"
#include "editor/plugins/editor_plugin.h"
#include "editor/scene/3d/node_3d_editor_plugin.h"
#include "scene/3d/xr/xr_nodes.h"

class SubViewport;

class EditorXRCamera3D : public XRCamera3D {
	GDCLASS(EditorXRCamera3D, XRCamera3D);

public:
	EditorXRCamera3D();
};

class ImmersiveTransformGizmo {
public:
	enum HandleKind {
		HANDLE_MOVE_AXIS,
		HANDLE_MOVE_PLANE,
		HANDLE_ROTATE_AXIS,
		HANDLE_SCALE_AXIS,
		HANDLE_SCALE_PLANE,
		HANDLE_KIND_COUNT,
	};

	struct Handle {
		HandleKind kind = HANDLE_MOVE_AXIS;
		int axis = -1;
		Vector3 grab_point;
	};

	static constexpr uint32_t LAYER = 31;

private:
	RID instances[HANDLE_KIND_COUNT][3];
	bool kind_shown[HANDLE_KIND_COUNT] = {};
	Transform3D gizmo_transform;
	Basis viewer_facing_basis;
	real_t gizmo_scale = 1.0;

	static Ref<ArrayMesh> _get_mesh(Node3DEditor *p_spatial_editor, HandleKind p_kind, int p_axis);
	static bool _is_kind_used_by_tool(HandleKind p_kind, Node3DEditor::ToolMode p_tool_mode);
	static bool _is_plane_kind(HandleKind p_kind);

	void _pick_axis_grabbers(HandleKind p_kind, real_t p_offset, real_t p_size, const Vector3 &p_ray_origin, const Vector3 &p_ray_direction, Handle &r_best, real_t &r_best_cost) const;
	void _pick_plane_grabbers(HandleKind p_kind, const Vector3 &p_ray_origin, const Vector3 &p_ray_direction, Handle &r_best, real_t &r_best_cost) const;
	bool _pick_rotation_ring(const Vector3 &p_ray_origin, const Vector3 &p_ray_direction, Handle &r_handle) const;

public:
	bool is_created() const { return instances[0][0].is_valid(); }
	void create(Node3DEditor *p_spatial_editor, RID p_scenario);
	void destroy();
	void show_at(const Transform3D &p_gizmo_transform, const Vector3 &p_viewer_position, Node3DEditor::ToolMode p_tool_mode);
	void hide();
	bool pick(const Vector3 &p_ray_origin, const Vector3 &p_ray_direction, Handle &r_handle) const;

	Vector3 get_origin() const { return gizmo_transform.origin; }
	Basis get_orthonormal_basis() const { return gizmo_transform.basis.orthonormalized(); }
	Vector3 get_axis_direction(int p_axis) const;
	Vector3 get_plane_handle_direction(int p_axis) const;
	static int get_highlight_index(const Handle &p_handle);
};

class ImmersiveEditorPlugin : public EditorPlugin {
	GDCLASS(ImmersiveEditorPlugin, EditorPlugin);

	struct GizmoDrag {
		bool active = false;
		int hand_index = -1;
		ImmersiveTransformGizmo::Handle handle;
		Vector3 center;
		Basis gizmo_frame;
		Vector3 axis_direction;
		Vector3 plane_handle_direction;
		Vector3 hand_start_position;
		real_t hand_to_object_gain = 1.0;
		bool local_coords = false;
		HashMap<Node3D *, Transform3D> original_global_transforms;
	};

	static constexpr int HAND_COUNT = 2;

	SubViewport *immersive_viewport = nullptr;
	XROrigin3D *immersive_origin = nullptr;
	EditorXRCamera3D *immersive_camera = nullptr;
	ImmersiveTransformGizmo transform_gizmo;
	GizmoDrag gizmo_drag;
	bool hand_was_pinching[HAND_COUNT] = { false, false };
	bool is_presenting_immersive_frames = false;
	bool low_processor_mode_before_immersion = true;
	bool needs_user_placement = false;
	Transform3D last_placed_editor_camera_transform;

	void _build_immersive_rig();
	void _keep_editor_drawing_while_immersed();
	void _match_viewport_to_xr_render_target();
	void _match_camera_layers_to_editor_viewport();
	void _place_user_at_editor_camera_when_it_moves();
	void _update_transform_gizmo();
	void _handle_pinches();
	void _begin_gizmo_drag(int p_hand_index, const Vector3 &p_hand_position);
	void _continue_gizmo_drag(const Vector3 &p_hand_position);
	void _finish_gizmo_drag();

	void _translate_selection(const Vector3 &p_grab_motion, Node3DEditor *p_spatial_editor);
	void _rotate_selection(const Vector3 &p_virtual_grab_point, Node3DEditor *p_spatial_editor);
	void _scale_selection(const Vector3 &p_grab_motion, Node3DEditor *p_spatial_editor);

	Camera3D *_get_editor_camera() const;
	Vector3 _get_viewer_position() const;
	Transform3D _tracking_to_world(const Transform3D &p_tracking_transform) const;
	bool _get_tracked_pose(const StringName &p_tracker_name, const StringName &p_pose_name, Transform3D &r_world_transform) const;
	LocalVector<Node3D *> _get_movable_selection() const;

protected:
	void _notification(int p_what);

public:
	virtual String get_plugin_name() const override { return "ImmersiveEditor"; }

	ImmersiveEditorPlugin();
};
