# Information about the loaded Julia library

Information about the loaded Julia library

## Usage

``` r
backend_info()
```

## Value

A list with:

- `path`: where the library is, or `NULL` if none is loaded.

- `clients`: the packages it was built from.

- `excluded`: the packages left out of it because their Julia
  dependencies conflict with those of other packages (see
  [`install_backend()`](https://bjarkehautop.github.io/jlbind/reference/install_backend.md)).

- `bound`: the packages bound to it.

- `objects`: how many Julia objects R holds references to.

## Examples

``` r
backend_info()
#> $path
#> NULL
#> 
#> $clients
#> NULL
#> 
#> $excluded
#> NULL
#> 
#> $bound
#> character(0)
#> 
#> $objects
#> NULL
#> 
```
