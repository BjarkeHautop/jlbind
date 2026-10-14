# Package index

## Building the library

Compile the Julia code of the installed packages that use jlbind.

- [`install_backend()`](https://bjarkehautop.github.io/jlbind/reference/install_backend.md)
  : Build the Julia library
- [`build_library()`](https://bjarkehautop.github.io/jlbind/reference/build_library.md)
  : Build a Julia library from specific packages
- [`jlbind_clients()`](https://bjarkehautop.github.io/jlbind/reference/jlbind_clients.md)
  : List the packages that use jlbind

## At run time

Bind a package to the compiled library, and check on it.

- [`bind()`](https://bjarkehautop.github.io/jlbind/reference/bind.md) :
  Bind a package to the Julia library
- [`is_bound()`](https://bjarkehautop.github.io/jlbind/reference/is_bound.md)
  [`check_backend()`](https://bjarkehautop.github.io/jlbind/reference/is_bound.md)
  : Check whether a package is bound to the Julia library
- [`backend_info()`](https://bjarkehautop.github.io/jlbind/reference/backend_info.md)
  : Information about the loaded Julia library

## Package development

Set up a package to use jlbind.

- [`use_jlbind()`](https://bjarkehautop.github.io/jlbind/reference/use_jlbind.md)
  : Set up a package to use jlbind
- [`update_entrypoints()`](https://bjarkehautop.github.io/jlbind/reference/update_entrypoints.md)
  : Update the list of Julia functions R can call
