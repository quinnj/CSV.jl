
# CSV

[![CI](https://github.com/JuliaData/CSV.jl/workflows/CI/badge.svg)](https://github.com/JuliaData/CSV.jl/actions?query=workflow%3ACI)
[![codecov](https://codecov.io/gh/JuliaData/CSV.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/JuliaData/CSV.jl)
[![deps](https://juliahub.com/docs/CSV/deps.svg)](https://juliahub.com/ui/Packages/CSV/HHBkp?t=2)
[![version](https://juliahub.com/docs/CSV/version.svg)](https://juliahub.com/ui/Packages/CSV/HHBkp)
[![pkgeval](https://juliahub.com/docs/CSV/pkgeval.svg)](https://juliahub.com/ui/Packages/CSV/HHBkp)

*A fast, flexible delimited file reader/writer for Julia.*

## Installation

The package is registered in the [`General`](https://github.com/JuliaRegistries/General) registry and so can be installed at the REPL with `] add CSV`.

## Documentation

- [**STABLE**][docs-stable-url] &mdash; **most recently tagged version of the documentation.**
- [**LATEST**][docs-latest-url] &mdash; *in-development version of the documentation.*

## Project Status

The package is tested against Julia `1.0`, current stable release, and nightly on Linux, OS X, and Windows.

## Contributing and Questions

Contributions are very welcome, as are feature requests and suggestions. Please open an
[issue][issues-url] if you encounter any problems or would just like to ask a question.

[docs-latest-img]: https://img.shields.io/badge/docs-latest-blue.svg
[docs-latest-url]: https://JuliaData.github.io/CSV.jl/latest

[docs-stable-img]: https://img.shields.io/badge/docs-stable-blue.svg
[docs-stable-url]: https://JuliaData.github.io/CSV.jl/stable

[ci-img]: https://github.com/JuliaData/CSV.jl/workflows/CI/badge.svg
[ci-url]: https://github.com/JuliaData/CSV.jl/actions?query=workflow%3ACI+branch%3Amaster

[codecov-img]: https://codecov.io/gh/JuliaData/CSV.jl/branch/master/graph/badge.svg
[codecov-url]: https://codecov.io/gh/JuliaData/CSV.jl

[issues-url]: https://github.com/JuliaData/CSV.jl/issues

## Alternatives

There are several other packages for reading CSV files in Julia, which may suit your needs better:

* The standard library contains [DelimitedFiles.jl](https://docs.julialang.org/en/v1/stdlib/DelimitedFiles/).
  This returns a `Matrix` rather than a [Tables.jl](https://github.com/JuliaData/Tables.jl)-style container, thus works best for files of homogenous element type. 
  On large files, CSV.jl will be much faster.

* [CSVFiles.jl](https://github.com/queryverse/CSVFiles.jl) uses the [FileIO.jl](https://github.com/JuliaIO/FileIO.jl) API 
  into any [IterableTables.jl](https://github.com/queryverse/IterableTables.jl) sink.
  The package uses [TextParse.jl](https://github.com/queryverse/TextParse.jl) for parsing.

* [DLMReader.jl](https://github.com/sl-solution/DLMReader.jl) also aims to be fast for large files,
  closely associated with [InMemoryDatasets.jl](https://github.com/sl-solution/InMemoryDatasets.jl).

* [Pandas.jl](https://github.com/JuliaPy/Pandas.jl) wraps Python's [pandas](https://pandas.pydata.org) library (using [PyCall.jl](https://github.com/JuliaPy/PyCall.jl)).
  This is a closer cousin of [DataFrames.jl](https://github.com/JuliaData/DataFrames.jl), but builds in the ability to read/write CSV files.
