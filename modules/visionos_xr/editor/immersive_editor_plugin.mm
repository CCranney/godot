/**************************************************************************/
/*  immersive_editor_plugin.mm                                            */
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


#include "immersive_editor_plugin.h"

#include "../visionos_xr_interface.h"

#include "core/math/geometry_3d.h"
#include "core/math/plane.h"
#include "core/os/os.h"
#include "editor/editor_data.h"
#include "editor/editor_node.h"
#include "editor/editor_undo_redo_manager.h"
#include "editor/scene/3d/node_3d_editor_constants.h"
#include "editor/scene/3d/node_3d_editor_viewport.h"
#include "scene/main/viewport.h"
#include "scene/resources/3d/world_3d.h"
#include "scene/resources/mesh.h"
#include "servers/rendering/rendering_server.h"
#include "servers/xr/xr_pose.h"
#include "servers/xr/xr_positional_tracker.h"
#include "servers/xr/xr_server.h"

using namespace Node3DEditorConstants;

static constexpr real_t VISIONOS_MINIMUM_NEAR_PLANE = 0.1;
static constexpr real_t IMMERSIVE_GIZMO_SCALE_PER_METER = 0.08;
static constexpr real_t MINIMUM_HAND_DISTANCE = 0.1;
static constexpr real_t GRABBER_TOLERANCE = 1.5;
static constexpr real_t MINIMUM_SCALE_FACTOR = 0.001;
static const char *const HAND_TRACKER_NAMES[] = { "left_hand", "right_hand" };
static const char *const EYES_RAY_TRACKER_NAME = "/user/eyes_ext";

static Basis yaw_only(const Basis &p_basis) {
	Vector3 forward = -p_basis.get_column(2);
	forward.y = 0;
	if (forward.length_squared() < CMP_EPSILON) {
		return Basis();
	}
	return Basis::looking_at(forward.normalized());
}

static Transform3D origin_placing_head_at(const Transform3D &p_target, const Transform3D &p_head_in_tracking_space) {
	Basis origin_basis = yaw_only(p_target.basis) * yaw_only(p_head_in_tracking_space.basis).inverse();
	return Transform3D(origin_basis, p_target.origin - origin_basis.xform(p_head_in_tracking_space.origin));
}

static real_t signed_angle_around(const Vector3 &p_axis, const Vector3 &p_from, const Vector3 &p_to) {
	Vector3 from_on_plane = p_from - p_axis * p_from.dot(p_axis);
	Vector3 to_on_plane = p_to - p_axis * p_to.dot(p_axis);
	if (from_on_plane.is_zero_approx() || to_on_plane.is_zero_approx()) {
		return 0.0;
	}
	return Math::atan2(p_axis.dot(from_on_plane.cross(to_on_plane)), from_on_plane.dot(to_on_plane));
}

EditorXRCamera3D::EditorXRCamera3D() {
	set_desired_process_modes(true, false);
	set_near(VISIONOS_MINIMUM_NEAR_PLANE);
}

Ref<ArrayMesh> ImmersiveTransformGizmo::_get_mesh(Node3DEditor *p_spatial_editor, HandleKind p_kind, int p_axis) {
	switch (p_kind) {
		case HANDLE_MOVE_AXIS:
			return p_spatial_editor->get_move_gizmo(p_axis);
		case HANDLE_MOVE_PLANE:
			return p_spatial_editor->get_move_plane_gizmo(p_axis);
		case HANDLE_ROTATE_AXIS:
			return p_spatial_editor->get_rotate_gizmo(p_axis);
		case HANDLE_SCALE_AXIS:
			return p_spatial_editor->get_scale_gizmo(p_axis);
		case HANDLE_SCALE_PLANE:
			return p_spatial_editor->get_scale_plane_gizmo(p_axis);
		default:
			return Ref<ArrayMesh>();
	}
}

bool ImmersiveTransformGizmo::_is_kind_used_by_tool(HandleKind p_kind, Node3DEditor::ToolMode p_tool_mode) {
	switch (p_kind) {
		case HANDLE_MOVE_AXIS:
		case HANDLE_MOVE_PLANE:
			return p_tool_mode == Node3DEditor::TOOL_MODE_TRANSFORM || p_tool_mode == Node3DEditor::TOOL_MODE_MOVE;
		case HANDLE_ROTATE_AXIS:
			return p_tool_mode == Node3DEditor::TOOL_MODE_TRANSFORM || p_tool_mode == Node3DEditor::TOOL_MODE_ROTATE;
		case HANDLE_SCALE_AXIS:
		case HANDLE_SCALE_PLANE:
			return p_tool_mode == Node3DEditor::TOOL_MODE_SCALE;
		default:
			return false;
	}
}

bool ImmersiveTransformGizmo::_is_plane_kind(HandleKind p_kind) {
	return p_kind == HANDLE_MOVE_PLANE || p_kind == HANDLE_SCALE_PLANE;
}

void ImmersiveTransformGizmo::create(Node3DEditor *p_spatial_editor, RID p_scenario) {
	RenderingServer *rendering_server = RenderingServer::get_singleton();
	for (int kind = 0; kind < HANDLE_KIND_COUNT; kind++) {
		for (int axis = 0; axis < 3; axis++) {
			RID instance = rendering_server->instance_create();
			rendering_server->instance_set_base(instance, _get_mesh(p_spatial_editor, HandleKind(kind), axis)->get_rid());
			rendering_server->instance_set_scenario(instance, p_scenario);
			rendering_server->instance_set_visible(instance, false);
			rendering_server->instance_geometry_set_cast_shadows_setting(instance, RSE::SHADOW_CASTING_SETTING_OFF);
			rendering_server->instance_set_layer_mask(instance, 1u << LAYER);
			rendering_server->instance_geometry_set_flag(instance, RSE::INSTANCE_FLAG_IGNORE_OCCLUSION_CULLING, true);
			rendering_server->instance_geometry_set_flag(instance, RSE::INSTANCE_FLAG_USE_BAKED_LIGHT, false);
			instances[kind][axis] = instance;
		}
	}
}

void ImmersiveTransformGizmo::destroy() {
	for (int kind = 0; kind < HANDLE_KIND_COUNT; kind++) {
		for (int axis = 0; axis < 3; axis++) {
			if (instances[kind][axis].is_valid()) {
				RenderingServer::get_singleton()->free_rid(instances[kind][axis]);
				instances[kind][axis] = RID();
			}
		}
		kind_shown[kind] = false;
	}
}

void ImmersiveTransformGizmo::show_at(const Transform3D &p_gizmo_transform, const Vector3 &p_viewer_position, Node3DEditor::ToolMode p_tool_mode) {
	gizmo_transform = p_gizmo_transform;
	gizmo_scale = MAX(p_viewer_position.distance_to(gizmo_transform.origin), VISIONOS_MINIMUM_NEAR_PLANE) * IMMERSIVE_GIZMO_SCALE_PER_METER;
	const Vector3 viewer_to_gizmo = p_viewer_position.direction_to(gizmo_transform.origin);

	viewer_facing_basis = get_orthonormal_basis();
	for (int column = 0; column < 3; column++) {
		if (viewer_facing_basis.get_column(column).dot(viewer_to_gizmo) > CMP_EPSILON) {
			viewer_facing_basis.set_column(column, -viewer_facing_basis.get_column(column));
		}
	}

	RenderingServer *rendering_server = RenderingServer::get_singleton();
	for (int axis = 0; axis < 3; axis++) {
		Vector3 axis_direction = get_axis_direction(axis);
		Vector3 next_axis_direction = get_axis_direction((axis + 1) % 3);
		Transform3D axis_transform;
		if (axis_direction.dot(next_axis_direction) < 1.0) {
			axis_transform = axis_transform.looking_at(axis_direction, next_axis_direction);
		}
		axis_transform.basis.scale(Vector3(1, 1, 1) * gizmo_scale);
		axis_transform.origin = gizmo_transform.origin;

		Transform3D plane_transform = axis_transform;
		for (int column = 0; column < 3; column++) {
			if (plane_transform.basis.get_column(column).normalized().dot(viewer_to_gizmo) > CMP_EPSILON) {
				plane_transform.basis.set_column(column, -plane_transform.basis.get_column(column));
			}
		}

		for (int kind = 0; kind < HANDLE_KIND_COUNT; kind++) {
			const Transform3D &handle_transform = _is_plane_kind(HandleKind(kind)) ? plane_transform : axis_transform;
			rendering_server->instance_set_transform(instances[kind][axis], handle_transform);
		}
	}

	for (int kind = 0; kind < HANDLE_KIND_COUNT; kind++) {
		kind_shown[kind] = _is_kind_used_by_tool(HandleKind(kind), p_tool_mode);
		for (int axis = 0; axis < 3; axis++) {
			rendering_server->instance_set_visible(instances[kind][axis], kind_shown[kind]);
		}
	}
}

void ImmersiveTransformGizmo::hide() {
	for (int kind = 0; kind < HANDLE_KIND_COUNT; kind++) {
		if (!kind_shown[kind]) {
			continue;
		}
		for (int axis = 0; axis < 3; axis++) {
			RenderingServer::get_singleton()->instance_set_visible(instances[kind][axis], false);
		}
		kind_shown[kind] = false;
	}
}

void ImmersiveTransformGizmo::_pick_axis_grabbers(HandleKind p_kind, real_t p_offset, real_t p_size, const Vector3 &p_ray_origin, const Vector3 &p_ray_direction, Handle &r_best, real_t &r_best_cost) const {
	const real_t grabber_radius = gizmo_scale * p_size * 0.5 * GRABBER_TOLERANCE;
	for (int axis = 0; axis < 3; axis++) {
		const Vector3 grabber_position = gizmo_transform.origin + get_axis_direction(axis) * gizmo_scale * (p_offset + p_size * 0.5);
		Vector3 hit;
		if (!Geometry3D::segment_intersects_sphere(p_ray_origin, p_ray_origin + p_ray_direction * MAX_Z, grabber_position, grabber_radius, &hit)) {
			continue;
		}
		const real_t cost = (grabber_position - p_ray_origin).cross(p_ray_direction).length() / grabber_radius;
		if (cost < r_best_cost) {
			r_best_cost = cost;
			r_best.kind = p_kind;
			r_best.axis = axis;
			r_best.grab_point = hit;
		}
	}
}

void ImmersiveTransformGizmo::_pick_plane_grabbers(HandleKind p_kind, const Vector3 &p_ray_origin, const Vector3 &p_ray_direction, Handle &r_best, real_t &r_best_cost) const {
	const real_t grabber_size = gizmo_scale * GIZMO_PLANE_SIZE * 0.5 * GRABBER_TOLERANCE;
	for (int axis = 0; axis < 3; axis++) {
		const Vector3 plane_diagonal = viewer_facing_basis.get_column((axis + 1) % 3) + viewer_facing_basis.get_column((axis + 2) % 3);
		const Vector3 grabber_position = gizmo_transform.origin + plane_diagonal * gizmo_scale * (GIZMO_PLANE_DST + GIZMO_PLANE_SIZE * 0.5);
		const Plane handle_plane(viewer_facing_basis.get_column(axis), gizmo_transform.origin);
		Vector3 hit;
		if (!handle_plane.intersects_ray(p_ray_origin, p_ray_direction, &hit)) {
			continue;
		}
		const real_t cost = hit.distance_to(grabber_position) / grabber_size;
		if (cost < 1.0 && cost < r_best_cost) {
			r_best_cost = cost;
			r_best.kind = p_kind;
			r_best.axis = axis;
			r_best.grab_point = hit;
		}
	}
}

bool ImmersiveTransformGizmo::_pick_rotation_ring(const Vector3 &p_ray_origin, const Vector3 &p_ray_direction, Handle &r_handle) const {
	const Transform3D orthonormal_gizmo(get_orthonormal_basis(), gizmo_transform.origin);
	const real_t ring_radius = gizmo_scale * GIZMO_CIRCLE_SIZE;
	const real_t ring_half_width = gizmo_scale * GIZMO_RING_HALF_WIDTH;

	Vector3 sphere_hit;
	Vector3 sphere_normal;
	const real_t ray_length = gizmo_transform.origin.distance_to(p_ray_origin) + ring_radius * 4.0;
	if (Geometry3D::segment_intersects_sphere(p_ray_origin, p_ray_origin + p_ray_direction * ray_length, gizmo_transform.origin, ring_radius, &sphere_hit, &sphere_normal) &&
			sphere_normal.dot(p_ray_direction) < 0.05) {
		const Vector3 local_hit = orthonormal_gizmo.xform_inv(sphere_hit).abs();
		const int closest_axis = local_hit.min_axis_index();
		if (local_hit[closest_axis] < ring_half_width) {
			r_handle.kind = HANDLE_ROTATE_AXIS;
			r_handle.axis = closest_axis;
			r_handle.grab_point = sphere_hit;
			return true;
		}
	}

	real_t closest_hit_distance = 1e20;
	for (int axis = 0; axis < 3; axis++) {
		const Plane ring_plane(get_axis_direction(axis), gizmo_transform.origin);
		Vector3 hit;
		if (!ring_plane.intersects_ray(p_ray_origin, p_ray_direction, &hit)) {
			continue;
		}
		const real_t distance_from_center = hit.distance_to(gizmo_transform.origin);
		const bool is_front_half = p_ray_direction.dot((hit - gizmo_transform.origin).normalized()) <= 0.005;
		const bool is_on_ring = distance_from_center > ring_radius - ring_half_width && distance_from_center < ring_radius + ring_half_width;
		const real_t hit_distance = p_ray_origin.distance_to(hit);
		if (is_front_half && is_on_ring && hit_distance < closest_hit_distance) {
			closest_hit_distance = hit_distance;
			r_handle.kind = HANDLE_ROTATE_AXIS;
			r_handle.axis = axis;
			r_handle.grab_point = hit;
		}
	}
	return r_handle.axis != -1;
}

bool ImmersiveTransformGizmo::pick(const Vector3 &p_ray_origin, const Vector3 &p_ray_direction, Handle &r_handle) const {
	r_handle = Handle();
	real_t best_cost = 1e20;

	if (kind_shown[HANDLE_MOVE_AXIS]) {
		_pick_axis_grabbers(HANDLE_MOVE_AXIS, GIZMO_ARROW_OFFSET, GIZMO_ARROW_SIZE, p_ray_origin, p_ray_direction, r_handle, best_cost);
		_pick_plane_grabbers(HANDLE_MOVE_PLANE, p_ray_origin, p_ray_direction, r_handle, best_cost);
		if (r_handle.axis != -1) {
			return true;
		}
	}

	if (kind_shown[HANDLE_ROTATE_AXIS] && _pick_rotation_ring(p_ray_origin, p_ray_direction, r_handle)) {
		return true;
	}

	if (kind_shown[HANDLE_SCALE_AXIS]) {
		_pick_axis_grabbers(HANDLE_SCALE_AXIS, GIZMO_SCALE_OFFSET, GIZMO_SCALE_SIZE, p_ray_origin, p_ray_direction, r_handle, best_cost);
		_pick_plane_grabbers(HANDLE_SCALE_PLANE, p_ray_origin, p_ray_direction, r_handle, best_cost);
	}
	return r_handle.axis != -1;
}

Vector3 ImmersiveTransformGizmo::get_axis_direction(int p_axis) const {
	return gizmo_transform.basis.get_column(p_axis).normalized();
}

Vector3 ImmersiveTransformGizmo::get_plane_handle_direction(int p_axis) const {
	return (viewer_facing_basis.get_column((p_axis + 1) % 3) + viewer_facing_basis.get_column((p_axis + 2) % 3)).normalized();
}

int ImmersiveTransformGizmo::get_highlight_index(const Handle &p_handle) {
	switch (p_handle.kind) {
		case HANDLE_MOVE_AXIS:
			return p_handle.axis;
		case HANDLE_ROTATE_AXIS:
			return p_handle.axis + 3;
		case HANDLE_MOVE_PLANE:
			return p_handle.axis + 6;
		case HANDLE_SCALE_AXIS:
			return p_handle.axis + 9;
		case HANDLE_SCALE_PLANE:
			return p_handle.axis + 12;
		default:
			return -1;
	}
}

ImmersiveEditorPlugin::ImmersiveEditorPlugin() {
	_build_immersive_rig();
	set_process(true);
}

void ImmersiveEditorPlugin::_build_immersive_rig() {
	immersive_viewport = memnew(SubViewport);
	immersive_viewport->set_use_xr(true);
	immersive_viewport->set_update_mode(SubViewport::UPDATE_ALWAYS);
	immersive_viewport->set_disable_input(true);
	add_child(immersive_viewport);

	immersive_origin = memnew(XROrigin3D);
	immersive_viewport->add_child(immersive_origin);

	immersive_camera = memnew(EditorXRCamera3D);
	immersive_origin->add_child(immersive_camera);
	immersive_camera->set_current(true);
}

void ImmersiveEditorPlugin::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_PROCESS: {
			_keep_editor_drawing_while_immersed();
			_match_viewport_to_xr_render_target();
			_match_camera_layers_to_editor_viewport();
			if (is_presenting_immersive_frames) {
				_place_user_at_editor_camera_when_it_moves();
				_handle_pinches();
			}
			_update_transform_gizmo();
		} break;
		case NOTIFICATION_EXIT_TREE: {
			transform_gizmo.destroy();
		} break;
	}
}

void ImmersiveEditorPlugin::_keep_editor_drawing_while_immersed() {
	Ref<VisionOSXRInterface> visionos_xr_interface = VisionOSXRInterface::find_interface();
	bool compositor_frame_requested = visionos_xr_interface.is_valid() && visionos_xr_interface->is_compositor_frame_requested();
	if (compositor_frame_requested == is_presenting_immersive_frames) {
		return;
	}
	is_presenting_immersive_frames = compositor_frame_requested;

	OS *os = OS::get_singleton();
	if (is_presenting_immersive_frames) {
		low_processor_mode_before_immersion = os->is_in_low_processor_usage_mode();
		os->set_low_processor_usage_mode(false);
		needs_user_placement = true;
	} else {
		os->set_low_processor_usage_mode(low_processor_mode_before_immersion);
		if (gizmo_drag.active) {
			_finish_gizmo_drag();
		}
	}
}

void ImmersiveEditorPlugin::_match_viewport_to_xr_render_target() {
	Ref<XRInterface> primary_interface = XRServer::get_singleton()->get_primary_interface();
	if (primary_interface.is_null()) {
		return;
	}
	Size2i render_target_size = primary_interface->get_render_target_size();
	if (render_target_size.x > 1 && render_target_size.y > 1 && immersive_viewport->get_size() != render_target_size) {
		immersive_viewport->set_size(render_target_size);
	}
}

void ImmersiveEditorPlugin::_match_camera_layers_to_editor_viewport() {
	Camera3D *editor_camera = _get_editor_camera();
	if (editor_camera == nullptr) {
		return;
	}
	uint32_t editor_viewport_gizmo_layer = 1u << Node3DEditorViewport::GIZMO_BASE_LAYER;
	uint32_t cull_mask = (editor_camera->get_cull_mask() & ~editor_viewport_gizmo_layer) | (1u << ImmersiveTransformGizmo::LAYER);
	immersive_camera->set_cull_mask(cull_mask);
}

void ImmersiveEditorPlugin::_place_user_at_editor_camera_when_it_moves() {
	Camera3D *editor_camera = _get_editor_camera();
	if (editor_camera == nullptr) {
		return;
	}
	Transform3D editor_camera_transform = editor_camera->get_global_transform();
	if (!needs_user_placement && editor_camera_transform.is_equal_approx(last_placed_editor_camera_transform)) {
		return;
	}
	Transform3D head_in_tracking_space = immersive_camera->get_transform();
	if (head_in_tracking_space.origin.is_zero_approx()) {
		return;
	}
	immersive_origin->set_transform(origin_placing_head_at(editor_camera_transform, head_in_tracking_space));
	last_placed_editor_camera_transform = editor_camera_transform;
	needs_user_placement = false;
}

void ImmersiveEditorPlugin::_update_transform_gizmo() {
	Node3DEditor *spatial_editor = Node3DEditor::get_singleton();
	if (spatial_editor == nullptr || spatial_editor->get_move_gizmo(0).is_null()) {
		return;
	}
	if (!transform_gizmo.is_created()) {
		Ref<World3D> immersive_world = immersive_viewport->find_world_3d();
		if (immersive_world.is_null()) {
			return;
		}
		transform_gizmo.create(spatial_editor, immersive_world->get_scenario());
	}

	Transform3D gizmo_transform = spatial_editor->get_gizmo_transform();
	bool should_show = is_presenting_immersive_frames &&
			spatial_editor->is_gizmo_visible() &&
			gizmo_transform.basis.determinant() != 0 &&
			!_get_movable_selection().is_empty();

	if (should_show) {
		transform_gizmo.show_at(gizmo_transform, _get_viewer_position(), spatial_editor->get_tool_mode());
	} else {
		transform_gizmo.hide();
	}
}

void ImmersiveEditorPlugin::_handle_pinches() {
	for (int hand_index = 0; hand_index < HAND_COUNT; hand_index++) {
		Ref<XRPositionalTracker> hand_tracker = XRServer::get_singleton()->get_tracker(HAND_TRACKER_NAMES[hand_index]);
		Transform3D hand_world_transform;
		bool is_pinching = hand_tracker.is_valid() && bool(hand_tracker->get_input("trigger_click")) &&
				_get_tracked_pose(HAND_TRACKER_NAMES[hand_index], "aim", hand_world_transform);
		bool was_pinching = hand_was_pinching[hand_index];
		hand_was_pinching[hand_index] = is_pinching;

		bool drag_belongs_to_hand = gizmo_drag.active && gizmo_drag.hand_index == hand_index;
		if (is_pinching && !was_pinching && !gizmo_drag.active) {
			_begin_gizmo_drag(hand_index, hand_world_transform.origin);
		} else if (is_pinching && drag_belongs_to_hand) {
			_continue_gizmo_drag(hand_world_transform.origin);
		} else if (!is_pinching && drag_belongs_to_hand) {
			_finish_gizmo_drag();
		}
	}
}

void ImmersiveEditorPlugin::_begin_gizmo_drag(int p_hand_index, const Vector3 &p_hand_position) {
	Transform3D eyes_ray;
	if (!_get_tracked_pose(EYES_RAY_TRACKER_NAME, "default", eyes_ray)) {
		return;
	}
	ImmersiveTransformGizmo::Handle picked_handle;
	if (!transform_gizmo.pick(eyes_ray.origin, -eyes_ray.basis.get_column(2).normalized(), picked_handle)) {
		return;
	}
	LocalVector<Node3D *> movable_selection = _get_movable_selection();
	if (movable_selection.is_empty()) {
		return;
	}

	Node3DEditor *spatial_editor = Node3DEditor::get_singleton();
	gizmo_drag = GizmoDrag();
	gizmo_drag.active = true;
	gizmo_drag.hand_index = p_hand_index;
	gizmo_drag.handle = picked_handle;
	gizmo_drag.center = transform_gizmo.get_origin();
	gizmo_drag.gizmo_frame = transform_gizmo.get_orthonormal_basis();
	gizmo_drag.axis_direction = transform_gizmo.get_axis_direction(picked_handle.axis);
	gizmo_drag.plane_handle_direction = transform_gizmo.get_plane_handle_direction(picked_handle.axis);
	gizmo_drag.hand_start_position = p_hand_position;
	gizmo_drag.local_coords = spatial_editor->are_local_coords_enabled();

	Vector3 viewer_position = _get_viewer_position();
	real_t hand_distance = MAX(viewer_position.distance_to(p_hand_position), MINIMUM_HAND_DISTANCE);
	gizmo_drag.hand_to_object_gain = MAX(1.0, viewer_position.distance_to(picked_handle.grab_point) / hand_distance);

	for (Node3D *node : movable_selection) {
		gizmo_drag.original_global_transforms[node] = node->get_global_transform();
	}
	spatial_editor->select_gizmo_highlight_axis(ImmersiveTransformGizmo::get_highlight_index(picked_handle));
}

void ImmersiveEditorPlugin::_continue_gizmo_drag(const Vector3 &p_hand_position) {
	Node3DEditor *spatial_editor = Node3DEditor::get_singleton();
	Vector3 grab_motion = (p_hand_position - gizmo_drag.hand_start_position) * gizmo_drag.hand_to_object_gain;

	switch (gizmo_drag.handle.kind) {
		case ImmersiveTransformGizmo::HANDLE_MOVE_AXIS:
		case ImmersiveTransformGizmo::HANDLE_MOVE_PLANE:
			_translate_selection(grab_motion, spatial_editor);
			break;
		case ImmersiveTransformGizmo::HANDLE_ROTATE_AXIS:
			_rotate_selection(gizmo_drag.handle.grab_point + grab_motion, spatial_editor);
			break;
		case ImmersiveTransformGizmo::HANDLE_SCALE_AXIS:
		case ImmersiveTransformGizmo::HANDLE_SCALE_PLANE:
			_scale_selection(grab_motion, spatial_editor);
			break;
		default:
			break;
	}
	spatial_editor->update_transform_gizmo();
}

void ImmersiveEditorPlugin::_translate_selection(const Vector3 &p_grab_motion, Node3DEditor *p_spatial_editor) {
	Vector3 offset;
	if (gizmo_drag.handle.kind == ImmersiveTransformGizmo::HANDLE_MOVE_AXIS) {
		real_t distance_along_axis = p_grab_motion.dot(gizmo_drag.axis_direction);
		if (p_spatial_editor->is_snap_enabled()) {
			distance_along_axis = Math::snapped(distance_along_axis, p_spatial_editor->get_translate_snap());
		}
		offset = gizmo_drag.axis_direction * distance_along_axis;
	} else {
		Vector3 motion_on_plane = p_grab_motion - gizmo_drag.axis_direction * p_grab_motion.dot(gizmo_drag.axis_direction);
		Vector3 motion_in_gizmo_frame = gizmo_drag.gizmo_frame.xform_inv(motion_on_plane);
		if (p_spatial_editor->is_snap_enabled()) {
			motion_in_gizmo_frame.snapf(p_spatial_editor->get_translate_snap());
		}
		offset = gizmo_drag.gizmo_frame.xform(motion_in_gizmo_frame);
	}

	for (const KeyValue<Node3D *, Transform3D> &original : gizmo_drag.original_global_transforms) {
		Transform3D moved = original.value;
		moved.origin += offset;
		original.key->set_global_transform(moved);
	}
}

void ImmersiveEditorPlugin::_rotate_selection(const Vector3 &p_virtual_grab_point, Node3DEditor *p_spatial_editor) {
	real_t angle = signed_angle_around(gizmo_drag.axis_direction, gizmo_drag.handle.grab_point - gizmo_drag.center, p_virtual_grab_point - gizmo_drag.center);
	if (p_spatial_editor->is_snap_enabled()) {
		angle = Math::deg_to_rad(Math::snapped(Math::rad_to_deg(angle), (real_t)p_spatial_editor->get_rotate_snap()));
	}
	Basis rotation(gizmo_drag.axis_direction, angle);

	for (const KeyValue<Node3D *, Transform3D> &original : gizmo_drag.original_global_transforms) {
		Transform3D rotated;
		rotated.basis = rotation * original.value.basis;
		rotated.origin = gizmo_drag.center + rotation.xform(original.value.origin - gizmo_drag.center);
		original.key->set_global_transform(rotated);
	}
}

void ImmersiveEditorPlugin::_scale_selection(const Vector3 &p_grab_motion, Node3DEditor *p_spatial_editor) {
	real_t grab_reach = gizmo_drag.handle.grab_point.distance_to(gizmo_drag.center);
	if (grab_reach < CMP_EPSILON) {
		return;
	}

	const int axis = gizmo_drag.handle.axis;
	Vector3 scale_factors(1, 1, 1);
	if (gizmo_drag.handle.kind == ImmersiveTransformGizmo::HANDLE_SCALE_AXIS) {
		real_t stretch = p_grab_motion.dot(gizmo_drag.axis_direction) / grab_reach;
		if (p_spatial_editor->is_snap_enabled()) {
			stretch = Math::snapped(stretch, p_spatial_editor->get_scale_snap() / 100);
		}
		scale_factors[axis] += stretch;
	} else {
		real_t stretch = p_grab_motion.dot(gizmo_drag.plane_handle_direction) / grab_reach;
		if (p_spatial_editor->is_snap_enabled()) {
			stretch = Math::snapped(stretch, p_spatial_editor->get_scale_snap() / 100);
		}
		scale_factors[(axis + 1) % 3] += stretch;
		scale_factors[(axis + 2) % 3] += stretch;
	}
	for (int component = 0; component < 3; component++) {
		scale_factors[component] = MAX(scale_factors[component], MINIMUM_SCALE_FACTOR);
	}

	Basis world_scale = gizmo_drag.gizmo_frame * Basis::from_scale(scale_factors) * gizmo_drag.gizmo_frame.transposed();
	for (const KeyValue<Node3D *, Transform3D> &original : gizmo_drag.original_global_transforms) {
		Transform3D scaled = original.value;
		if (gizmo_drag.local_coords) {
			scaled.basis = original.value.basis.scaled_local(scale_factors);
		} else {
			scaled.basis = world_scale * original.value.basis;
			scaled.origin = gizmo_drag.center + world_scale.xform(original.value.origin - gizmo_drag.center);
		}
		original.key->set_global_transform(scaled);
	}
}

void ImmersiveEditorPlugin::_finish_gizmo_drag() {
	static const char *const ACTION_NAMES[ImmersiveTransformGizmo::HANDLE_KIND_COUNT] = {
		"Move in Immersive View",
		"Move in Immersive View",
		"Rotate in Immersive View",
		"Scale in Immersive View",
		"Scale in Immersive View",
	};

	EditorUndoRedoManager *undo_redo = EditorUndoRedoManager::get_singleton();
	undo_redo->create_action(ACTION_NAMES[gizmo_drag.handle.kind]);
	for (const KeyValue<Node3D *, Transform3D> &original : gizmo_drag.original_global_transforms) {
		undo_redo->add_do_method(original.key, "set_global_transform", original.key->get_global_transform());
		undo_redo->add_undo_method(original.key, "set_global_transform", original.value);
	}
	undo_redo->commit_action(false);

	Node3DEditor::get_singleton()->select_gizmo_highlight_axis(-1);
	gizmo_drag = GizmoDrag();
}

Camera3D *ImmersiveEditorPlugin::_get_editor_camera() const {
	Node3DEditor *spatial_editor = Node3DEditor::get_singleton();
	if (spatial_editor == nullptr) {
		return nullptr;
	}
	Node3DEditorViewport *first_editor_viewport = spatial_editor->get_editor_viewport(0);
	if (first_editor_viewport == nullptr) {
		return nullptr;
	}
	return first_editor_viewport->get_camera_3d();
}

Vector3 ImmersiveEditorPlugin::_get_viewer_position() const {
	return immersive_camera->get_global_transform().origin;
}

Transform3D ImmersiveEditorPlugin::_tracking_to_world(const Transform3D &p_tracking_transform) const {
	return immersive_origin->get_global_transform() * p_tracking_transform;
}

bool ImmersiveEditorPlugin::_get_tracked_pose(const StringName &p_tracker_name, const StringName &p_pose_name, Transform3D &r_world_transform) const {
	Ref<XRPositionalTracker> tracker = XRServer::get_singleton()->get_tracker(p_tracker_name);
	if (tracker.is_null()) {
		return false;
	}
	Ref<XRPose> pose = tracker->get_pose(p_pose_name);
	if (pose.is_null()) {
		return false;
	}
	r_world_transform = _tracking_to_world(pose->get_transform());
	return true;
}

LocalVector<Node3D *> ImmersiveEditorPlugin::_get_movable_selection() const {
	LocalVector<Node3D *> movable_selection;
	EditorSelection *editor_selection = EditorNode::get_singleton()->get_editor_selection();
	for (Node *selected : editor_selection->get_top_selected_node_list()) {
		Node3D *node = Object::cast_to<Node3D>(selected);
		if (node != nullptr && node->is_inside_tree() && !node->has_meta("_edit_lock_")) {
			movable_selection.push_back(node);
		}
	}
	return movable_selection;
}
