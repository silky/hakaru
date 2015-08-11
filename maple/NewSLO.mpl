NewSLO := module ()
  option package;
  local t_pw, gensym, density, recognize, get_de, recognize_de,
        Diffop, Recognized, Nothing;
  export Integrand, applyintegrand,
         Lebesgue, Uniform, Gaussian, BetaD, GammaD,
         Ret, Bind, Msum, Weight, LO,
         HakaruToLO, integrate, LOToHakaru, unintegrate;

# FIXME Need eval/LO and eval/Integrand and eval/Bind to teach eval about our
# binders.  Both LO and Integrand bind from 1st arg to 2nd arg, whereas Bind
# binds from 2nd arg to 3rd arg.

  t_pw := 'specfunc(piecewise)';

# An integrand h is either an Integrand (our own binding construct for a
# measurable function to be integrated) or something that can be applied
# (probably proc, which should be applied immediately, or a generated symbol).

# TODO evalapply/Integrand instead of applyintegrand?
# TODO evalapply/{Ret,Bind,...} instead of integrate?!

  applyintegrand := proc(h, x)
    if h :: 'Integrand(name, anything)' then
      eval(op(2,h), op(1,h) = x)
    elif h :: procedure then
      h(x)
    else
      'applyintegrand'(h, x)
    end if
  end proc;

# Step 1 of 3: from Hakaru to Maple LO (linear operator)

  HakaruToLO := proc(m)
    local h;
    h := gensym('h');
    LO(h, integrate(m, h))
  end proc;

  integrate := proc(m, h)
    local x, n, i;
    if m :: 'Lebesgue()' then
      x := gensym('xl');
      Int(applyintegrand(h, x),
          x=-infinity..infinity)
    elif m :: 'Uniform(anything, anything)' then
      x := gensym('xu');
      Int(applyintegrand(h, x),
          x=op(1,m)..op(2,m)) / (op(2,m)-op(1,m))
    elif m :: 'Gaussian(anything, anything)' then
      x := gensym('xg');
      Int(density[op(0,m)](op(m))(x) * applyintegrand(h, x),
          x=-infinity..infinity)
    elif m :: 'BetaD(anything, anything)' then
      x := gensym('xb');
      Int(density[op(0,m)](op(m))(x) * applyintegrand(h, x),
          x=0..1)
    elif m :: 'GammaD(anything, anything)' then
      x := gensym('xr');
      Int(density[op(0,m)](op(m))(x) * applyintegrand(h, x),
          x=0..infinity)
    elif m :: 'Ret(anything)' then
      applyintegrand(h, op(1,m))
    elif m :: 'Bind(anything, name, anything)' then
      integrate(op(1,m), z -> integrate(eval(op(3,m), op(2,m) = z), h))
    elif m :: 'specfunc(Msum)' then
      `+`(op(map(integrate, [op(m)], h)))
    elif m :: 'Weight(anything, anything)' then
      op(1,m) * integrate(op(2,m), h)
    elif m :: t_pw then
      n := nops(m);
      piecewise(seq(`if`(i::even or i=n, integrate(op(i,m), h), op(i,m)),
                    i=1..n))
    elif m :: 'LO(name, anything)' then
      eval(op(2,m), op(1,m) = h)
    elif h :: procedure then
      x := gensym('xa');
      'integrate'(m, Integrand(x, h(x)))
    else
      'integrate'(m, h)
    end if
  end proc;

# Step 2 of 3: algebra (currently nothing)

# Step 3 of 3: from Maple LO (linear operator) back to Hakaru

  Bind := proc(m, x, n)
    if n = 'Ret'(x) then
      m # monad law: right identity
    elif m :: 'Ret(anything)' then
      eval(n, x = op(1,m)) # monad law: left identity
    else
      'Bind'(m, x, n)
    end if;
  end proc;

  Weight := proc(p, m)
    if p = 1 then
      m
    elif m :: 'Weight(anything, anything)' then
      'Weight'(p * op(1,m), op(2,m))
    else
      'Weight'(p, m)
    end if;
  end proc;

  LOToHakaru := proc(lo :: LO(name, anything))
    local h;
    h := gensym(op(1,lo));
    unintegrate(h, eval(op(2,lo), op(1,lo) = h), [])
  end proc;

  unintegrate := proc(h :: name, integral, context :: list)
    local x, lo, hi, m, w, recognition, subintegral,
          n, i, next_context, update_context;
    if integral :: 'Or(Int(anything, name=anything..anything),
                         int(anything, name=anything..anything))' then
      x := gensym(op([2,1],integral));
      (lo, hi) := op(op([2,2],integral));
      next_context := [op(context), x::RealRange(Open(lo), Open(hi))];
      # TODO: enrich context with x (measure class lebesgue)
      subintegral := eval(op(1,integral), op([2,1],integral) = x);
      m := unintegrate(h, subintegral, next_context);
      if m :: 'Weight(anything, anything)' then
        (w, m) := op(m)
      else
        w := 1
      end if;
      recognition := recognize(w, x, lo, hi) assuming op(next_context);
      if recognition :: 'Recognized(anything, anything)' then
        # Recognition succeeded
        Bind(op(1,recognition), x, Weight(op(2,recognition), m))
      else
        # Recognition failed
        m := Weight(w, m);
        if hi <> infinity then
          m := piecewise(x < hi, m, Msum())
        end if;
        if lo <> -infinity then
          m := piecewise(lo < x, m, Msum())
        end if;
        Bind(Lebesgue(), x, m)
      end if
    elif integral :: 'applyintegrand(anything, anything)'
         and op(1,integral) = h then
      Ret(op(2,integral))
    elif integral :: 'integrate(anything, anything)' then
      x := gensym('x');
      # TODO is there any way to enrich context in this case?
      Bind(op(1,integral), x,
           unintegrate(h, applyintegrand(op(2,integral), x), context))
    elif integral = 0 then
      Msum()
    elif integral :: `+` then
      Msum(op(map2(unintegrate, h, convert(integral, 'list'), context)))
    elif integral :: `*` then
      (subintegral, w) := selectremove(has, integral, h);
      if subintegral :: `*` then
        error "Nonlinear integral %1", integral
      end if;
      Weight(w, unintegrate(h, subintegral, context))
    elif integral :: t_pw then
      n := nops(integral);
      next_context := context;
      update_context := proc(c)
        local then_context;
        then_context := [op(next_context), c];
        next_context := [op(next_context), not c]; # Mutation!
        then_context
      end proc;
      piecewise(seq(piecewise(i::even,
                              unintegrate(h, op(i,integral),
                                          update_context(op(i-1,integral))),
                              i=n,
                              unintegrate(h, op(i,integral), next_context),
                              op(i,integral)),
                    i=1..n))
    else
      # Failure: return residual LO
      LO(h, integral)
    end if
  end proc;

  recognize := proc(weight, x, lo, hi)
    local de, Dx, f, w, res;
    res := Nothing;
    # no matter what, get the de.
    # TODO: might want to switch from x=0 sometimes
    de := get_de(weight, x, Dx, f);
    if de :: 'Diffop(anything, anything)' then
      res := recognize_de(op(de), Dx, f, weight, x, lo, hi)
    end if;
    if res = Nothing then
      w := simplify(weight * (hi - lo));
      if not (w :: 'SymbolicInfinity') then
        res := Recognized(Uniform(lo, hi), w)
      end if
    end if;
    res
  end proc;

  get_de := proc(dens, var, Dx, f)
    :: Or(Diffop(anything, set(function=anything)), Nothing);
    local de, init;
    try
      de := gfun[holexprtodiffeq](dens, f(var));
      if not (de = NULL) then
        if not (de :: set) then
          de := gfun[diffeqtohomdiffeq](de, f(var))
        end if;
        if not (de :: set) then
          de := {de}
        end if;
        init, de := selectremove(type, de, `=`);
        if nops(init) = 0 then
          init := map((val -> f(val) = eval(dens, var=val)), {0, 1/2, 1})
        end if;
        if nops(de) = 1 then
          return Diffop(DEtools[de2diffop](de[1], f(var), [Dx, var]), init)
        end if
      end if
    catch: # do nothing
    end try;
    Nothing
  end proc;

  recognize_de := proc(diffop, init, Dx, f, weight, var, lo, hi)
    local dist, ii, constraints, c0, a0, a1, scale, mu, sigma, a, b, pp;
    dist := Nothing;
    if lo = -infinity and hi = infinity and degree(diffop, Dx) = 1 then
      a0 := coeff(diffop, Dx, 0);
      a1 := coeff(diffop, Dx, 1);
      if degree(a0, var) = 1 and degree(a1, var) = 0 then
        scale := coeff(a0, var, 1);
        dist := Gaussian(-coeff(a0, var, 0)/scale,
                         sqrt(coeff(a1, var, 0)/scale));
      end if;
    elif lo = 0 and hi = 1 then
      pp := primpart(diffop, Dx);
      if degree(pp, Dx) = 1 then
        a0 := coeff(pp, Dx, 0);
        a1 := coeff(pp, Dx, 1);
        if degree(a0,var) = 1 and degree(a1,var) = 2
           and normal(coeff(a1,var,0)) = 0
           and normal(coeff(a1,var,2) + coeff(a1,var,1)) = 0 then
          dist := BetaD(coeff(a0, var, 0)/coeff(a1, var, 2) + 1,
                        -(coeff(a0, var, 1) +
                          coeff(a0, var, 0))/coeff(a1, var, 2) + 1);
        # degenerate case with b=1
        elif degree(a0,var) = 0 and degree(a1,var) = 1
             and normal(coeff(a1,var,0)) = 0 then
          dist := BetaD(-coeff(a0, var, 0)/coeff(a1, var, 1) + 1, 1);
        # degenerate case with a=1
        elif degree(a0,var) = 0 and degree(a1,var) = 1
             and normal(coeff(a1,var,1) + coeff(a1,var,0)) = 0 then
          dist := BetaD(1, -coeff(a0, var, 0)/coeff(a1, var, 1) + 1);
        end if;
      end if;
    elif lo = 0 and hi = infinity then
      # TODO GammaD
    end if;
    if dist <> Nothing then
      ii := map(convert, init, 'diff');
      constraints := eval(ii, f = (x -> c0*density[op(0,dist)](op(dist))(x)));
      c0 := eval(c0, solve(constraints, c0));
      if not (has(c0, 'c0')) then
        return Recognized(dist, c0)
      end if
    end if;
    Nothing
  end proc;

  density[Gaussian] := proc(mu, sigma) proc(x)
    1/sigma/sqrt(2)/sqrt(Pi)*exp(-(x-mu)^2/2/sigma^2)
  end proc end proc;
  density[BetaD] := proc(a, b) proc(x)
    x^(a-1)*(1-x)^(b-1)/Beta(a,b)
  end proc end proc;
  # Hakaru uses the alternate definition of gamma, so the args are backwards
  density[GammaD] := proc(shape,scale) proc(x)
    x^(shape-1)/scale^shape*exp(-x/scale)/GAMMA(shape);
  end proc end proc;

  gensym := module()
    export ModuleApply;
    local gs_counter;
    gs_counter := 0;
    ModuleApply := proc(x::name)
      gs_counter := gs_counter + 1;
      x || gs_counter;
    end proc;
  end module; # gensym

end module; # NewSLO
