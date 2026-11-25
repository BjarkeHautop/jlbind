## R CMD check results

0 errors \| 0 warnings \| 1 note

* This is a new release.

## Examples using \dontrun{}

Four functions have examples wrapped in \dontrun{}:

* `install_library()` and `build_library()` require Julia (>= 1.13) and other
  packages that use jlbind, and compiling can take a few minutes.
* `remove_library()` deletes the library the user has built from the user's
  cache directory.
* `bind_client()` is meant to be called from the `.onLoad()` of another package.
