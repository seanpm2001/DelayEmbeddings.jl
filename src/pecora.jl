#=
# Description of the algorithm and definition of used symbols

## 0. Input embedding
s is the input timeseries or Dataset.
On s one performs a d-dimensional embedding, that uses a combination of d timeseries
(with arbitrary amount of repetitions) and d delay times.

I.e. input is `s, τs, js`, with `js, τs` being tuples.

## 1. Core loop given a specific input embedding
Let v be a d-dimensional embedding, whose each entry is an arbitrary choice out of
the available timeseries (if we have multiple input timeseries, otherwise they are all the
same) and each entry is also defined with respect to an arbitrary delay.

Define a radius δ around v in R^d space (d-dimensional embedding). k points are inside
the δ-ball (with respect to some metric) around v. For simplicity, the time index of
v is t0. The other poinds inside the δ_ball have indices ti (with several i).

We want to check if we can add an additional dimension to the embedding, using the j-th
timeseries. We check with continuity statistic of Pecora et al.

let x(t+τ) ≡ s_j(t+τ) be this extra dimension we add into the embedding. Out of the
k points in the δ-ball, we count l of them that land into a range ε around x.  Notice that
"points" is a confusing term that should not be used interchange-bly. Here in truth we
refer to **indices** not points. Because of delay embedding, all points are mapped 1-to-1
to a unique time idex. We count the x points with the same time indices ti, if they
are around the original x point with index t0.

Now, if l ≥ δ_to_ε_amount[k] (where δ_to_ε_amount a dictionary defined below), we can
reject the null hypothesis (that the point mapping was by chance), and thus we satisfy
the continuity criterion.

## 2. Finding minimum ε

Notice that in the current code implementation, δ (which is a real number)
is never given/existing in code.
Let a fiducial point v, and we find the k nearest neighbors (say Vs)
and then map their indices to the ε-space. The map of the fiducial point in ε-space
is a and the map of the neighbors is As.

In the ε-space we calculate the distances of As from a. We then sort these distances.

We want the minimum range ε★ within which there are at least l (l = δ_to_ε_amount[k])
neighbors of a. This is simply the l-th maximum distance of As from a.
Why? because if ε★ was any smaller, one neighbor wouldn't be a neighbor anymore and
we would have 1 less l.

## 3. Averaging ε
We repeat step 1 and 2 for several different input points v, and possibly several
input `k`, and average the result in ε★_avg ≡ ⟨ε★⟩.

The larger ε★_avg, the more functionaly independent is the new d+1 entry to the rest
d entries of the embedding.

## Creating a proper embedding
The Pecora embedding is a sequential process. This means that one should start with
a 1-dimensional embedding, with delay time 0 (i.e. a single timeseries).
Then, one performs steps 1-3 for a
choice of one more embedded dimension, i.e. the j-th timeseries and a delay τ.
The optimal choice for the second dimension of the embedding is the j entry with highest
ε★_avg and τ in a local maximum of ε★_avg.

Then these two dimensions are used again as input to the algorithm, and sequentially
the third optimal entry for the embedding is chosen. Each added entry successfully
reduces ε★_avg for the next entry.

This process continues until ε cannot be reduced further, in which scenario the
process terminates and we have found an optimal embedding that maximizes
functional independence among the dimensions of the embedding.

## The undersampling statistic
Because real world data are finite, the aforementioned process (of seeing when ε★_avg
will saturate) isn't very accurate because as the dimension of v increases, we are
undersampling a high-dimensional object.

# TODO: Understand, describe, and implement the undersampling statistic

## Perforamance notes
for fnding points within ε, do y = sort!(x) and optimized count starting from index
of x and going up and down
=#

using Distances
export continuity_statistic

"""
Table 1 of Pecora (2007), i.e. the necessary amount of points for given δ points
that *must* be mapped into the ε set to reject the null hypothesis for p=0.5
and α=0.05.
"""
const δ_to_ε_amount = Dict(
    5=>5,
    6=>6,
    7=>7,
    8=>7,
    9=>8,
    10=>9,
    11=>9,
    12=>9,
    13=>10,
)

"""
    continuity_statistic(s, τs, js; kwargs...) → ⟨ε★⟩
Compute the (average) continuity statistic `⟨ε★⟩` according to Pecora et al. [1],
for a given input
`s` (timeseries or `Dataset`) and input embedding defined by `(τs, js)`,
see [`genembed`](@ref). The continuity statistic represents functional independence
between the components of the existing embedding (defined by `τs, js`) and
one additional timeseries.

The returned result is a *matrix* with size `T`x`J`.

## Keyword arguments
* `T=1:50` calculate `ε★` for all delay times in `T`.
* `J=1:dimension(s)` calculate `ε★` for all timeseries indices in `J`.
  This is always just 1 for
* `N=100` over how many fiducial points v to average ε★ to produce `⟨ε★⟩`
* `K = 7` the amount of nearest neighbors in the δ-ball (read algorithm description).

## Description
Notice that the full algorithm related with `ε★` is too large to discuss here, and is
written in detail in the source code of `continuity_statistic`.
"""
function continuity_statistic(s, τs::NTuple{D, Int}, js = NTuple{D, Int}(ones(D));
    T = 1:50, J=1:maxdimspan(s), N = 100, metric = Euclidean(), K = 7) where {D}

    vspace = genembed(s, τs, js)
    vtree = KDTree(vspace.data, metric)
    all_ε★ = zeros(length(T), length(J))
    allts = columns(s)
    # indices of random fiducial points (with valid time range w.r.t. T)
    ns = rand(max(1, (-minimum(T) + 1)):min(length(s), length(s) - maximum(T)), N)
    vs = vspace[ns]
    # Find all neighbors in one go (more performant).
    # Use `k+1` because it also fines the given points as neighbors as well.
    # We also do not need the distances of the points, only their indices
    # We do however sort distances, so that 2:k+1 are the actual neighbors
    # TODO: Improve this to have a theiler window exclusion
    allNNidxs, = NearestNeighbors.knn(vtree, vs, maximum(K)+1, true)
    # Loop over potential timeseries to use in new embedding
    for i in 1:length(J)
        x = allts[J[i]]
        all_ε★[:, i] .= continuity_statistic_per_timeseries(x, ns, allNNidxs, T, N, K)
    end
    return all_ε★
end

DelayEmbeddings.columns(s::AbstractVector) = (s, )
maxdimspan(s) = 1:dimension(s)
maxdimspan(s::AbstractVector) = 1

function continuity_statistic_per_timeseries(x::AbstractVector, ns, allNNidxs, T, N, K)
    k = K
    avrg_ε★ = zeros(size(T))
    c = 0
    for (i, n) in enumerate(ns) # Loop over fiducial points
        NNidxs = view(allNNidxs[i], 2:k+1) # indices of k nearest neighbors to v
        for (i, τ) in enumerate(T)
            # Check if any of the indices of the neighbors falls out of temporal range
            any(j -> (j+τ > length(x)) | (j+τ < 1), NNidxs) && continue
            # If not, calculate minimum ε
            avrg_ε★[i] += ε★(x, n, τ, NNidxs, k)
            c += 1
        end
    end
    c == 0 && error("Encountered astronomically small chance of all neighbors having "*
                    "invalid temporal range... Just run the function again!")
    avrg_ε★ ./= c
    return avrg_ε★
end

function ε★(x, n, τ, NNidxs, k)
    l = δ_to_ε_amount[k]
    a = x[n+τ] # fiducial point in ε-space
    @inbounds dis = [abs(a - x[i+τ]) for i in NNidxs]
    sortedds = sort!(dis; alg = QuickSort)
    # return l-th minimum distance
    # TODO: If we want to average over different k (different δ-neighborhoods)
    # we just average over different [l] in the following line:
    return sortedds[l]
end
