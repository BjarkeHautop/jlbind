# Check whether a package is bound to the Julia library

`is_bound()` returns `TRUE` or `FALSE`. `check_backend()` gives an error
that explains why the package isn't bound.

## Usage

``` r
is_bound(pkg)

check_backend(pkg)
```

## Arguments

- pkg:

  Name of a package that uses jlbind.

## Value

`is_bound()`: `TRUE` or `FALSE`. `check_backend()`: `TRUE` (invisibly)
if the package is bound, otherwise an error.

## Examples

``` r
# Not bound, as no package named mypkg has been loaded
is_bound("mypkg")
#> [1] FALSE
try(check_backend("mypkg"))
#> Error : Package mypkg has not asked to be bound; is it loaded, and does it call jlbind::bind() from its .onLoad()?
```
