export genepop

"""
    genepop(infile::String; kwargs...)
Load a Genepop format file into memory as a PopData object.
- `infile::String` : path to Genepop file

### Keyword Arguments
- `digits::Integer`: number of digits denoting each allele (default: `3`)
- `popsep::String` : word that separates populations in `infile` (default: "POP")
- `diploid::Bool`  : whether samples are diploid for parsing optimizations (default: `true`)
- `silent::Bool`   : whether to print file information during import (default: `true`)

### File must follow standard Genepop formatting:
- First line is a comment (and skipped)
- Loci are listed after first line as one-per-line without commas or in single comma-separated row
- A line with a particular keyword (default `POP`) must delimit populations
- Sample name is immediately followed by a *comma*
- File is *tab or space delimted* (but not both!)

### Genepop file example:
wasp_hive.gen: Wasp populations in New York \n
Locus1\n
Locus2\n
Locus3\n
pop\n
Oneida_01,  250230  564568  110100\n
Oneida_02,  252238  568558  100120\n
Oneida_03,  254230  564558  090100\n
pop\n
Newcomb_01, 254230  564558  080100\n
Newcomb_02, 000230  564558  090080\n
Newcomb_03, 254230  000000  090100\n
Newcomb_04, 254230  564000  090120\n

## Example
```
waspsNY = genepop("wasp_hive.gen", digits = 3, popsep = "pop")
```

"""
function genepop(
    infile::String;
    digits::Int = 3,
    popsep::String = "POP",
    diploid::Bool = true,
    silent::Bool = false,
)
    # open the file as lines of strings to suss out loci names, pop idx, and popcounts
    gpop_readlines = readlines(infile)

    # find the #samples per population
    pop_idx = Vector{Int}()
    for (line, gtext) in enumerate(gpop_readlines)
        gtext == popsep && push!(pop_idx, line)
    end
    length(pop_idx) == 0 &&
    error("No populations found in $infile using separator \"$popsep\". Please check the spelling and try again.")

    # create a theoretical place were the last popsep would be (preserve last population for counting)
    push!(pop_idx, countlines(infile) + 1)
    popcounts = (pop_idx[2:end] .- pop_idx[1:end-1]) .- 1

    # check for the delimiter type in the first sample record
    firstrecord = gpop_readlines[pop_idx[1]+1]
    if occursin("\t", firstrecord) & occursin(" ", firstrecord)
        error("$infile contains both tab and space delimiters. Please format the file so it uses either one or the other.")
    elseif occursin("\t", firstrecord)
        delim = "\t"
        delim_txt = "tab"
    elseif occursin(" ", firstrecord)
        delim = " "
        delim_txt = "space"
    else
        error("Please format $infile to be either tab or space delimited")
    end

    # check for horizontal formatting, where popsep would appear on the third line
    if pop_idx[1] <= 3
        # second line should have all the loci
        locus_name_raw = replace(gpop_readlines[2], "." => "_")
        locinames = strip.(split(locus_name_raw |> join, ","))
        format = "horizontal"
    else
        #standard  vertical formatting
        locinames = gpop_readlines[2:pop_idx[1]-1]
        format = "vertical"
    end

    if !silent
        @info "\n$(abspath(infile))\n$(delim_txt) delimiter detected\nloci formatting: $(format)\n$(sum(popcounts)) samples across $(length(popcounts)) populations detected\n$(length(locinames)) loci detected"
    end

    # load in samples and genotypes
    coln = append!(["name"], locinames)

    diploid ? type = nothing : type = String

    geno_parse = CSV.read(
        infile,
        delim = delim,
        header = coln,
        datarow = pop_idx[1] + 1,
        comment = popsep,
        missingstrings = ["-9", ""],
        type = type
    ) |> DataFrame

    popnames = string.(collect(1:length(popcounts)))
    popnames = fill.(popnames,popcounts) |> Base.Iterators.flatten |> collect
    insertcols!(geno_parse, 2, :population => popnames)
    geno_parse.name .= replace.(geno_parse.name, "," => "")
    geno_type = determine_marker(geno_parse, digits)
    # wide to long format
    geno_parse = DataFrames.stack(geno_parse, DataFrames.Not([:name, :population]))
    rename!(geno_parse, [:name, :population, :locus, :genotype])
    categorical!(geno_parse, [:name, :population, :locus], compress = true)
    geno_parse.genotype = map(i -> phase.(i, geno_type, digits), geno_parse.genotype)
    #return geno_parse

    # make sure levels are sorted by order of appearance
    levels!(geno_parse.locus, unique(geno_parse.locus))
    levels!(geno_parse.name, unique(geno_parse.name))

    ploidy = DataFrames.combine(
        groupby(dropmissing(geno_parse), :name),
        :genotype => find_ploidy => :ploidy
    ).ploidy

    # take a piece of the genotype table out and create a new table with the ploidy
    sample_table = DataFrame(
        name = levels(geno_parse.name),
        population = popnames,
        ploidy = ploidy,
        latitude = Vector{Union{Missing,Float32}}(undef, sum(popcounts)),
        longitude = Vector{Union{Missing,Float32}}(undef, sum(popcounts))
    )

    PopData(sample_table, geno_parse)
end

"""
    popdata2genepop(data::PopData; filename::String = "output.gen", digits::Int = 3, format::String = "vertical")
Writes a `PopData` object to a Genepop-formatted file.
- `data`: the `PopData` object you wish to convert to a Genepop file
### keyword arguments
- `filename`: a `String` of the output filename
- `digits` : an `Integer` indicating how many digits to format each allele as (e.g. `(1, 2)` => `001002` for `digits = 3`)
- `format` : a `String` indicating whether loci should be formatted
    - vertically (`"v"` or `"vertical"`)
    - hortizontally (`"h"`, or `"horizontal"`)
    - Genepop Isolation-By-Distance (`"ibd"`) where each sample is a population with long/lat data prepended

```julia
cats = nancycats();
fewer_cats = omit_samples(cats, samples(cats)[1:10]);
popdata2genepop(fewer_cats, filename = "filtered_nancycats.gen", digits = 3, format = "h")
```
"""
function popdata2genepop(data::PopData; filename::String = "output.gen", digits::Int = 3, format::String = "vertical")
    open(filename, "w") do outfile
        println(outfile, "genepop generated from PopData by PopGen.jl")
        if format in ["h", "horizontal"]
            [print(outfile, i, ",") for i in loci(data)[1:end-1]];
            print(outfile, loci(data)[end], "\n")
        else
            [println(outfile,i) for i in loci(data)];
        end
        if lowercase(format) != "ibd"
            println(outfile, "POP")
            pops = [unique(data.loci.population)[1]]
            for (keys, sample) in pairs(groupby(data.loci, [:name, :population]))
                print(outfile, sample.name[1], ",\t")
                format_geno = unphase.(sample.genotype, digits = digits)
                [print(outfile, i, "\t") for i in format_geno[1:end-1]]
                print(outfile, format_geno[end], "\n" )
                if keys.population != pops[end]
                    println(outfile, "POP")
                    push!(pops, keys.population)
                end
            end
        else
            for (keys, sample) in pairs(groupby(data.loci, :name))
                println(outfile, "POP")
                long = data.meta[data.meta.name .== keys.name, :longitude][1]
                lat = data.meta[data.meta.name .== keys.name, :latitude][1]
                print(outfile, long, "\t", lat, "\t", keys.name, ",\t")
                format_geno = unphase.(sample.genotype, digits = digits)
                [print(outfile, i, "\t") for i in format_geno[1:end-1]]
                print(outfile, format_geno[end], "\n" )
            end
        end
    end
end