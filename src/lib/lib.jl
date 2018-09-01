# Interfaces

accum() = nothing
accum(x) = x

accum(x, y) =
  x == nothing ? y :
  y == nothing ? x :
  x + y

accum(x, y, zs...) = accum(accum(x, y), zs...)

accum(x::Tuple, y::Tuple) = accum.(x, y)
accum(x::AbstractArray, y::AbstractArray) = accum.(x, y)

@generated function accum(x::NamedTuple, y::NamedTuple)
  grad(x) = x in fieldnames(y) ? :(y.$x) : :nothing
  Expr(:tuple, [:($f=accum(x.$f, $(grad(f)))) for f in fieldnames(x)]...)
end

using MacroTools: combinedef

_gradtuple(::Nothing) = nothing
_gradtuple(x::Tuple) = (nothing, x...)
_gradtuple(x) = error("Gradient $x should be a tuple")

function gradm(f, T, args, Ts, body, mut)
  args = esc.(args)
  Ts = esc.(Ts)
  pushfirst!(args, :($(esc(:__context__))::Context), :($f::$T))
  body = quote
    Base.@_inline_meta
    y, back = $(esc(body))
    $(mut ? nothing : :(back2(::Nothing) = nothing))
    # return needed for type inference
    back2(Δ) = return _gradtuple(back(Δ))
    y, back2
  end
  :(Zygote._forward($(args...)) where $(Ts...) = $body; nothing)
end

_gradtuple_kw(::Nothing) = nothing
_gradtuple_kw(x::Tuple) = (nothing, nothing, nothing, x...) # kwfunc, kws, func, args...
_gradtuple_kw(x) = error("Gradient $x should be a tuple")
_untuple_kw(::Nothing) = nothing
_untuple_kw(x::Tuple) = Base.tail(Base.tail(x))

function gradm_kw(f, T, args, Ts, body, mut)
  kws = popfirst!(args)
  Ts = esc.(Ts)
  kT = :(Core.kwftype($T))
  kwargs = [:($(esc(:__context__))::Context), :(::$kT), :kw, f, esc.(args)...]
  kw_wrappers = map(kws.args) do kw
    kw isa Symbol && return :($(esc(kw)) = kw.$kw)
    k, v = kw.args
    :($(esc(k)) = haskey(kw, $(Expr(:quote, k))) ? kw.$k : $(esc(v)))
  end
  body = quote
    Base.@_inline_meta
    $(kw_wrappers...)
    y, back = $(esc(body))
    $(mut ? nothing : :(back2(::Nothing) = nothing))
    # return needed for type inference
    back2(Δ) = return _gradtuple_kw(back(Δ))
    y, back2
  end
  quote
    Zygote._forward($(kwargs...)) where $(Ts...) = $body
    function Zygote._forward(cx::Context, f::$T, $(esc.(args)...)) where $(Ts...)
      y, back = _forward(cx, Core.kwfunc(f), NamedTuple(), f, $(esc.(namify.(args))...)) # TODO unnamed arguments
      return y, Δ -> _untuple_kw(back(Δ))
    end
    nothing
  end
end

function gradm(ex, mut = false)
  @capture(shortdef(ex), (name_(args__) = body_) |
                         (name_(args__) where {Ts__} = body_)) || error("Need a function definition")
  iskw = length(args) > 1 && isexpr(args[1], :parameters)
  name, T = isexpr(name, :(::)) ?
    (length(name.args) == 1 ? (:_, esc(name.args[1])) : esc.(name.args)) :
    (:_, :(typeof($(esc(name)))))
  Ts == nothing && (Ts = [])
  return (iskw ? gradm_kw : gradm)(name, T, args, Ts, body, mut)
end

macro grad(ex)
  gradm(ex)
end

macro grad!(ex)
  gradm(ex, true)
end

macro nograd(ex)
  isexpr(ex, :tuple) || (ex = Expr(:tuple, ex))
  blk = :(;)
  for f in ex.args
    push!(blk.args, :(@inline Zygote._forward(::Context, ::typeof($(esc(f))), args...) = $(esc(f))(args...), Δ -> nothing))
  end
  return blk
end

# Core functions

@nograd Core.apply_type, Core.typeof, nfields, fieldtype,
  (==), (===), (>=), (<), (>), isempty

@grad (::Type{V})(x...) where V<:Val = V(x...), _ -> nothing

@grad ifelse(cond::Bool, t, f) =
  ifelse(cond, t, f),
  Δ -> cond ? (Δ, zero(Δ)) : (zero(Δ), Δ)

@grad Base.typeassert(x, T) = Base.typeassert(x, T), Δ -> (Δ, nothing)

function accum_param(cx::Context, x, Δ)
  haskey(cache(cx), x) && (cache(cx)[x] = accum(cache(cx)[x],Δ))
  return
end

unwrap(x) = x

@grad unwrap(x) = unwrap(x), Δ -> accum_param(__context__, x, Δ)

# Tuples

@grad tuple(xs...) = xs, identity

@grad getindex(xs::NTuple{N,Any}, i::Integer) where N =
  (xs[i], Δ -> (ntuple(j -> i == j ? Δ : nothing, Val(N)), nothing))

# Needed for iteration lowering
@grad Core.getfield(xs::NTuple{N,Any}, i::Integer) where N =
  (xs[i], Δ -> (ntuple(j -> i == j ? Δ : nothing, Val(N)), nothing))

_empty(x) = nothing
_empty(x::Tuple) = map(_empty, x)

_unapply(t, xs) = first(xs), tail(xs)
_unapply(t::Tuple{}, xs) = (), xs

function _unapply(t::Tuple, xs)
  t1, xs1 = _unapply(first(t), xs)
  t2, xs2 = _unapply(tail(t), xs1)
  (t1, t2...), xs2
end

unapply(t, xs) = _unapply(t, xs)[1]

@grad function Core._apply(f, args...)
  y, J = Core._apply(_forward, (__context__, f), args...)
  let st = _empty(args), J = J
    y, function (Δ)
      Δ = J(Δ)
      (first(Δ), unapply(st, Base.tail(Δ))...)
    end
  end
end

# Structs

deref!(x) = x

function deref!(x::Ref)
  d = x[]
  x[] = nothing
  return d
end

@generated nt_nothing(x) = Expr(:tuple, [:($f=nothing) for f in fieldnames(x)]...)

@generated pair(::Val{k}, v) where k = :($k = v,)

# TODO make this inferrable
@grad function getfield(x, f::Symbol)
  val = getfield(x, f)
  unwrap(val), function (Δ)
    accum_param(__context__, val, Δ)
    if isimmutable(x)
      ((;nt_nothing(x)...,pair(Val{f}(), Δ)...), nothing)
    else
      dx = getfield(grad_mut(__context__, x), f)
      dx[] = accum(dx[], Δ)
      return
    end
  end
end

@generated function grad_mut(x)
  Expr(:tuple, [:($f = Ref{Any}(nothing)) for f in fieldnames(x)]...)
end

function grad_mut(cx::Context, x)
  T = Core.Compiler.return_type(grad_mut, Tuple{typeof(x)})
  ch = cache(cx)
  if haskey(ch, x)
    ch[x]::T
  else
    ch[x] = grad_mut(x)
  end
end

@grad! function setfield!(x, f, val)
  y = setfield!(x, f, val)
  g = grad_mut(__context__, x)
  y, function (_)
    r = getfield(g, f)
    Δ = deref!(r)
    (nothing, nothing, Δ)
  end
end

@generated function __new__(T, args...)
  quote
    Base.@_inline_meta
    $(Expr(:new, :T, [:(args[$i]) for i = 1:length(args)]...))
  end
end

struct Jnew{T,G}
  g::G
end

Jnew{T}(g) where T = Jnew{T,typeof(g)}(g)

@grad! function __new__(T, args...)
  x = __new__(T, args...)
  g = !T.mutable || fieldcount(T) == 0 ? nothing : grad_mut(__context__, x)
  x, Jnew{T}(g)
end

# TODO captured mutables + multiple calls to `back`
@generated function (back::Jnew{T,G})(Δ) where {T,G}
  !T.mutable && Δ == Nothing && return :nothing
  Δ = G == Nothing ? :Δ : :(back.g)
  :(nothing, $(map(f -> :(deref!($Δ.$f)), fieldnames(T))...))
end
