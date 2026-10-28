from SCons.Errors import UserError

from platform_methods import setup_swift_builder


def select_sources_for_library_type(file_names, library_type, executable_only=frozenset(), library_only=frozenset()):
    _require_listed_sources_exist(executable_only | library_only, file_names)
    excluded_names = library_only if library_type == "executable" else executable_only
    return [name for name in file_names if name not in excluded_names]


def setup_swift_builder_for_executables(env, *swift_builder_arguments):
    if env["library_type"] != "executable":
        return []
    return setup_swift_builder(env, *swift_builder_arguments)


def _require_listed_sources_exist(listed_names, file_names):
    stale_names = sorted(set(listed_names) - set(file_names))
    if stale_names:
        raise UserError(f"Library-type source lists name files that no longer exist: {', '.join(stale_names)}")
