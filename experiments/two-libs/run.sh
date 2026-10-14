#!/bin/sh
# Reproduce the experiment; see README.md. Needs Julia >= 1.13 and R.
set -e
cd "$(dirname "$0")"
julia --startup-file=no build.jl liba out
julia --startup-file=no build.jl libb out
julia --startup-file=no --project=combined -e 'import Pkg; Pkg.develop([Pkg.PackageSpec(path="liba"), Pkg.PackageSpec(path="libb")])'
julia --startup-file=no build.jl combined out
echo "== separate libraries, A first (expected: abort)"; Rscript test.R ab || true
echo "== separate libraries, B first (expected: abort)"; Rscript test.R ba || true
echo "== combined library (expected: OK)"; Rscript t3.R
