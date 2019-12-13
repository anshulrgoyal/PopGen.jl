"""
    locations(data::PopObj)
View location data (`.longitude` and `.latitude`) in a `PopObj`. Returns a view
of the PopObj, not a new DataFrame, therefor *manual editing of the output will
alter the source PopObj*.

Use `locations!` to add spatial data to a `PopObj`
"""
function locations(data::PopObj)
    @view data.samples[!, [:name, :population, :longitude, :latitude]]
end

"""
    locations!(data::PopObj; lat::Array, long::Array)
Add location data (latitude `lat`, longitude `long`) to `PopObj`. Takes decimal
degrees or decimal minutes format. **Must** use `-` symbol instead of cardinal directions.
Location data must be in order of `ind`. Replaces existing `PopObj` location data.
- Decimal Degrees : `-11.431`
- Decimal Minutes : `"-11 43.11"` (must use space and double-quotes)

If conversion is not necessary, can directly assign `PopObj.samples.longitude` and `PopObj.samples.latitude`
"""
function locations!(data::PopObj; lat::Array, long::Array)
    # test for decimal degrees vs decimal minutes
    if occursin(" ", string(lat[1])) == false && occursin(" ", string(long[1])) == false
        data.samples.longitude = lat ;
        data.samples.latitude = long ;
    else
        @info "Converting decimal minutes to decimal degrees"
        # make sure decimal minutes are Strings
        if typeof(lat) != Vector{String}
            lat = string.(lat)
        end
        if typeof(long) != Vector{String}
            long = string.(long)
        end

        # convert lat to decimal degrees
        latConverted = Vector{Float32}()
        for value in lat
            tmp = split(value, " ")
            if parse(Float64,tmp[1]) < 0
                # if negative, subtract
                decideg = parse(Float32, tmp[1]) - round((parse(Float32,tmp[2])/60), digits = 3)
                push!(latConverted, decideg)
            else
                # if positive, add
                decideg = parse(Float32, tmp[1]) + round((parse(Float32,tmp[2])/60), digits = 3)
                push!(latConverted, decideg)
            end
        end

        # convert long to decimal degrees
        longConverted = Vector{Float32}()
        for value in long
            tmp = split(value, " ")
            if parse(Float64,tmp[1]) < 0
                decideg = parse(Float64, tmp[1]) - round((parse(Float64,tmp[2])/60), digits = 3)
                push!(longConverted, decideg)
            else
                decideg = parse(Float64, tmp[1]) + round((parse(Float64,tmp[2])/60), digits = 3)
                push!(longConverted, decideg)
            end
        end
        data.samples.longitude = latConverted
        data.samples.latitude = longConverted
    end
end

"""
    loci(data::PopObj)
Returns an array of strings of the loci names in a `PopObj`
"""
function loci(data::PopObj)
    String.(names(data.loci))
end

"""
    loci(data::DataFrame)
Convenience wrapper to return an array of column names as string in the `.loci`
DataFrame of a `PopObj`
"""
function loci(data::DataFrame)
    String.(names(data))
end


#### Find missing ####

"""
    missing(data::PopObj)
Identify and count missing loci in each sample of a `PopObj`. Returns a tuple
of `DataFrames`: loci per sample, number per loci.

Example:

`missing_ind,missing_loc = missing(gulfsharks)`
"""
function Base.missing(data::PopObj)
    # missing per sample
    ind_geno = map(i -> get_sample_genotypes(data, i), data.samples.name)
    count_miss_ind = map(ind_geno) do ind
        count(i -> i === missing, ind)
    end

    # which loci are missing per sample
    loci_names = loci(data)
    miss_loci = map(ind_geno) do ind
        [loci_names[i] for i in findall(j -> j === missing, ind)]
    end

    # missing per locus
    miss_per_loci = map(eachcol(data.loci)) do col
        count(i->i===missing, col)
    end

    # create DataFrames of the two
    by_sample_df = DataFrame(
        name = data.samples.name,
        population = data.samples.population,
        missing = count_miss_ind,
        loci = miss_loci |> Vector{Vector{String}}
    )

    by_locus_df = DataFrame(
        locus = loci_names,
        missing = miss_per_loci
    )

    return by_sample_df, by_locus_df
end

"""
    populations(data::PopObj; listall::Bool = false)
View unique population ID's in a `PopObj`.

`listall = true`, displays `ind` and their `population` instead (default = `false`).
"""
function populations(data::PopObj; listall::Bool = false)
    if listall == true
        @view data.samples[!, [:name, :population]]
    else
        if ismissing.(data.samples.population) |> unique == [true]
            @info "no population data present in PopObj"
            return @view data.samples[!, [:name, :population]]
        end
        popcounts = [count(i -> i == j, data.samples.population) for j in unique(data.samples.population)]
        popcounts = DataFrame(
            population = unique(data.samples.population),
            count = popcounts
        )
    end
end

"""
    populations!(data::PopObj; rename::Dict, replace::Union{Tuple, NamedTuple})
Assign population names to a `PopObj`. There are two modes of operation:

## Rename

Rename existing population ID's of `PopObj.population` using a `Dict` of `[population] => replacement`

Example:

`potatopops = Dict(1 => "Idaho", 2 => "Russet")`

`populations!(potatoes, rename = potatopops)`

## Replace (overwrite)
Completely replace the population names of a `PopObj` regardless of what they currently are.
Will generate an array of population names from a tuple of (counts, names) where `counts` is
an array of the number of samples per population and `names` is an array of the names of the
populations. Can also use a named tuple.

Example assigning names for three populations in a `PopObj` named "Starlings":
Assuming population sizes are 15, 32, 11 and we want to name them "North", "South", "East"

`populations!(Starlings, replace = ([15,32,11], ["North","South", "East"])`
`populations!(Starlings, replace = (counts = [15,32,11], names = ["North","South", "East"])`
"""
function populations!(data::PopObj; rename::Dict=Dict(), replace::Union{Tuple,NamedTuple}=(0,0))
    if length(keys(rename)) != 0
        for eachkey in keys(rename)
            eachkey ∉ data.samples.population && @warn "$eachkey not found in PopObj"
            replace!(data.samples.population, eachkey => rename[eachkey])
        end
        @info "renaming populations"
        return populations(data,listall = true)
    elseif replace != (0,0)
        if typeof(replace) <: NamedTuple
            popid_array = [fill(i, j) for (i,j) in zip(replace.names, replace.counts)]
        else typeof(replace) <: Tuple
            popid_array = [fill(i, j) for (i,j) in zip(replace[2], replace[1])]
        end
        flat_popid = Iterators.flatten(popid_array) |> collect
        length(flat_popid) != size(data.samples, 1) && error("length of names ($(length(flat_popid))) does not match sample number ($(length(data.samples.name)))")
        data.samples.population = flat_popid
        @info "overwriting all population names"
        return populations(data, listall = true)
    else
        error("specify rename = Dict() to rename populations, or replace=(counts,names) to replace all names")
    end
end

const population = populations
const population! = populations!


##### Removal #####

"""
    remove_loci!(data::PopObj, loci::Union{String, Vector{String}})
Removes selected loci from a `PopObj`.

Examples:

`remove_loci!(nancycats, "fca8")`

`remove_loci!(nancycats, ["fca8", "fca23"])`
"""
function remove_loci!(data::PopObj, loci::Union{String,Vector{String}})

    # get individuals indices
    if typeof(loci) == String
        sym_loci = Symbol(loci)
        sym_loci ∉ names(data.loci) && error("Locus \"$loci\" not found")
        return select!(data.loci, Not(sym_loci))
    else
        sym_loci = Symbol.(loci)
        for each in sym_loci
            if each ∉ names(data.loci)
                println("NOTICE: locus \"$each\" not found")
                continue
            end
        end
        return select!(data.loci, Not(sym_loci))
    end
end


"""
    remove_samples!(data::PopObj, samp_id::Union{Vector{String}})
Removes selected samples from a `PopObj`.

Examples:

`remove_samples!(nancycats, "N100")`

`remove_samples!(nancycats, ["N100", "N102", "N211"])`
"""
function remove_samples!(data::PopObj, samp_id::Union{String, Vector{String}})
    # get samp_id indices
    if typeof(samp_id) == String
        samp_id ∉ data.samples.name && error("sample \"$samp_id\" not found")
        idx = findfirst(i -> i == samp_id, data.samples.name)
    else
        idx = []
        for ind in samp_id
            if ind ∉ data.samples.name
                println("NOTICE: sample \"$ind\" not found!")
                continue
            end
            push!(idx, findfirst(i -> i == ind, data.samples.name) )
        end
        println()
    end
    deleterows!(data.samples, idx)
    deleterows!(data.loci, idx)
    return data
end

"""
    samples(data::PopObj)
View individual/sample names in a `PopObj`

Equivalent to `PopObj.samples.name`
"""
function samples(data::PopObj)
    data.samples.name
end

"""
    summary(data::PopObj)
Prints a summary of the information contained in a PopObj
"""
function Base.summary(data::PopObj)

    println("Object of type $(typeof(data)):")
    if typeof(data.loci[!, :1][1][1]) == Int16
        marker = "Microsatellite"
    else
        marker = "SNP"
    end
    println("Marker type: $marker")
    println("\nLongitude:")
    println("$(data.samples.longitude[1:3])" , " \u2026 ", "$(data.samples.longitude[end-2:end])", "\n")
    println("Latitude:")
    println("$(data.samples.latitude[1:3])" , " \u2026 ", "$(data.samples.latitude[end-2:end])", "\n")
    println("Number of individuals: $(length(data.samples.name))")
    println(data.samples.name[1:3] , " \u2026 ", data.samples.name[end-2:end], "\n")
    println("Number of loci: $(size(data.loci,2))")
    println(string.(names(data.loci))[1:3], " \u2026 " , string.(names(data.loci))[end-2:end], "\n" )
    println("Ploidy:")
    println("$(data.samples.ploidy[1:3])", " \u2026 ", "$(data.samples.ploidy[end-2:end])", "\n")
    println("Population names and counts:")
    print(populations(data), "\n")
    println("\nAvailable .samples fields: .name, .population, .ploidy, .longitude, .latitude")
end


"""
    view_genotypes(data::PopObj; samples::Union{String, Array, Nothing}, loci::Union{String, Array, Nothing})
Returns a dataframe of samples, population, genotypes. View the genotypes of
specific samples for specific loci in a `PopObj`. Default shows all genotypes
for all individuals.

`view_genotypes(nancycats, loci = "fca8")`

`view_genotypes(nancycats, samples = "N226", loci = ["fca8", "fca23"])`
"""
function view_genotypes(data::PopObj; samples::Union{String, Array, Nothing}= nothing, loci::Union{String, Array, Nothing}= nothing)
    if loci == nothing && samples == nothing
        @warn "please specify either loci= or samples=, otherwise use PopObj.loci"
    end

    df = deepcopy(data.loci)
    insertcols!(df, 1, :name => data.samples.name) ;
    insertcols!(df, 2, :population => categorical(data.samples.population))
    if samples != nothing
        if typeof(samples) == String
            samples ∉ data.samples.name && error("individual $samples not found in PopObj")
            tmp = df[df.name .== samples, :]
        else
            tmp = df[df.name .== samples[1], :]
            for ind in samples[2:end]
                ind ∉ data.samples.name && println("NOTICE: individual \"$ind\" not found in PopObj!")
                tmp = vcat(tmp, df[df.name .== ind, :])
            end
            println()
        end
    else
        tmp = df
    end
    if loci != nothing
        if typeof(loci) == String
            loci ∉ string.(names(data.loci)) && error("locus $loci not found in PopObj")
            return tmp[!, [:name, :population, Symbol(loci)]]
        else
            for locus in loci[2:end]
                locus ∉ string.(names(data.loci)) && println("NOTICE: locus \"$locus\" not found in PopObj!")
            end
            println()
            return tmp[!, append!([:name, :population], Symbol.(loci))]
        end
    else
        return tmp
    end
end
