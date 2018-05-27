module grain.functions;

import grain.autograd;
import grain.cuda;

import std.stdio;

version (grain_cuda) {
    import cudnn = derelict.cudnn7;
}


mixin template TypeChecker(alias forward, alias backward) {
    static assert(allSatisfy!(isVariable, Parameters!forward),
                  "all the forward function args should be variable.");
    static assert(allSatisfy!(isVariable, Parameters!backward),
                  "all the backward function args should be variable.");
    // static assert(arity!forward == Tuple!(ReturnType!backward).length);
    // static assert(arity!backward == Tuple!(ReturnType!forward).length);
    static if (arity!forward == 1 && arity!backward == 1) {
        static assert(is(ReturnType!backward == Parameters!forward[0]));
        static assert(is(ReturnType!forward == Parameters!backward[0]));
    } else static if (arity!backward == 1) {
        static assert(is(ReturnType!backward == Tuple!(Parameters!forward)));
        static assert(is(ReturnType!forward == Parameters!backward[0]));
    } else static if (arity!forward == 1) {
        static assert(is(ReturnType!backward == Parameters!forward[0]));
        static assert(is(ReturnType!forward == Tuple!(Parameters!backward)));
    } else {
        static assert(is(ReturnType!backward == Tuple!(Parameters!forward)));
        static assert(is(ReturnType!forward == Tuple!(Parameters!backward)));
    }
}

mixin template FunctionCommon() {
    import std.meta : allSatisfy;
    import std.typecons : isTuple, tuple, Tuple, RefCounted;
    import std.traits : arity, Parameters, ReturnType;

    RefCounted!(UntypedVariable[]) vargs,  vrets;

    static foreach (i, forward; __traits(getOverloads, typeof(this), "forward")) {
        static foreach (i, backward; __traits(getOverloads, typeof(this), "backward")) {
            static if (!allSatisfy!(isHost, Parameters!forward) &&
                       !allSatisfy!(isHost, Parameters!backward)) {
                alias DeviceRets = Tuple!(Parameters!backward);
                alias DeviceArgs = Tuple!(Parameters!forward);
                mixin TypeChecker!(forward, backward);
            }
            static if (allSatisfy!(isHost, Parameters!forward) &&
                       allSatisfy!(isHost, Parameters!backward)) {
                alias HostRets = Tuple!(Parameters!backward);
                alias HostArgs = Tuple!(Parameters!forward);
                mixin TypeChecker!(forward, backward);
            }
        }
    }

    auto applyForward(Args...)(Args args) {
        import std.algorithm : each;
        this.vargs.length = args.length;
        this.vrets.length = HostRets.length; // TODO: remove this line
        foreach (i, a; args) {
            this.vargs[i] = UntypedVariable(a);
        }
        auto ret = this.forward(args);
        static if (isTuple!(typeof(ret))) {
            auto rets = ret;
        } else {
            auto rets = tuple(ret);
        }

        enum isHost = allSatisfy!(isHost, Args);
        auto ugradOuts = new UntypedVariable[rets.length];
        foreach (i, r; rets) {
            auto u = UntypedVariable(r);
            if (grain.autograd.backprop) {
                RefCounted!BackProp bp = BackProp(&this.applyBackward!isHost,
                                                  this.vargs, ugradOuts);
                u.bprop = bp;
                u.outPosition = i;
                rets[i].bprop = bp;
            }
            this.vrets[i] = u;
        }
        static if (isTuple!(typeof(ret))) {
            return rets;
        } else {
            return rets[0];
        }
    }

    void applyBackward(bool isHost)(UntypedVariable[] ugradOutputs, UntypedVariable[] uinputs) {
        static if (isHost) {
            HostRets vgradOutputs;
        } else {
            DeviceRets vgradOutputs;
        }
        static foreach (i; 0 .. vgradOutputs.length) {
            vgradOutputs[i] = ugradOutputs[i].to!(typeof(vgradOutputs[i]));
        }
        static if (vgradOutputs.length == 1) {
            auto _vgradInputs = this.backward(vgradOutputs[0]);
        } else {
            auto _vgradInputs = vgradOutputs.apply!(this.backward);
        }
        static if (isTuple!(typeof(_vgradInputs))) {
            auto vgradInputs = _vgradInputs;
        } else {
            auto vgradInputs = tuple(_vgradInputs);
        }
        auto ugradInputs = new UntypedVariable[vgradInputs.length];
        foreach (i, v; vgradInputs) {
            ugradInputs[i] = UntypedVariable(v);
        }
        assert(vgradInputs.length == uinputs.length, "invalid number of input gradients");
        foreach (i, vgi; vgradInputs) {
            if (uinputs[i].requiresGrad) {
                alias Storage = typeof(vgradInputs[i].data);
                alias V = typeof(vgradInputs[i]);
                static if (vgradInputs[i].isHost) {
                    import mir.ndslice.slice : sliced;
                    auto gs = uinputs[i].gradSlice!V;
                    gs[] += vgradInputs[i].data[].sliced(gs.shape);
                } else {
                    auto data = uinputs[i].grad.get!Storage;
                    axpy(vgradInputs[i].data, data);
                }
            }
            uinputs[i].backward(&ugradInputs[i]);
        }
    }
}

/// test NG functions
unittest {
    alias F1H = Variable!(float, 1, HostStorage);
    version (grain_cuda) alias F1D = Variable!(float, 1, HostStorage);
    struct A(DelayInstantiation) {
        mixin FunctionCommon;
        // mismatch of args
        F1H forward(F1H x) { return x; };
        F1H backward(F1H x, F1H y) { return x; };
    }
    static assert(!__traits(compiles, A!void));

    version (grain_cuda) {
        struct B(DelayInstantiation) {
            mixin FunctionCommon;
            F1H forward(F1H x) { return x; };
            F1H backward(F1H x) { return x; };
            // mismatch of args in device
            version (grain_cuda) {
                F1D forward(F1D x) { return x; };
                F1D backward(F1D x, F1D y) { return x; };
            }
        }
        static assert(!__traits(compiles, B!void));
    }
}

struct ReLU(T, size_t dim) {
    mixin FunctionCommon;
    bool inplace = false;
    bool useCuDNN = true;
    Variable!(T, dim, HostStorage) hx;

    auto forward(Variable!(T, dim, HostStorage) x) {
        import mir.ndslice : each;
        // FIXME if train
        this.hx = x.dup;
        auto y = this.inplace ? x : x.dup;
        y.sliced.each!((ref a) { if (a < 0) a = 0; });
        return y;
    }

    auto backward(Variable!(T, dim, HostStorage) gy) {
        auto gx = gy.dup;
        foreach (i; 0..gx.data.length) {
            if (this.hx.data[i] < 0.0) gx.data[i] = 0.0;
        }
        return gx;
    }

    // TODO use cudnn
    version(grain_cuda) {
        import grain.cudnn;
        Variable!(T, dim, DeviceStorage) dx, dy;

        auto forward(Variable!(T, dim, DeviceStorage) x) {
            // FIXME if train
            this.dx = x.dup;
            auto y = this.inplace ? x : x.dup;

            if (this.useCuDNN) {
                this.dy = y;
                activationForward!CUDNN_ACTIVATION_RELU(x, y);
            } else {
                import grain.kernel : relu;
                auto n = cast(uint) y.data.length; // FIXME use y.nElement
                Global.kernel!relu
                    .call(y.data.ptr, n).launch([1,1,1], [n,1,1]);
            }
            return y;
        }

        auto backward(Variable!(T, dim, DeviceStorage) gy) {
            auto gx = gy.dup; // TODO: create empty
            if (this.useCuDNN) {
                activationBackward!CUDNN_ACTIVATION_RELU(gx, gy, dx, dy);
            } else {
                import grain.kernel : reluGrad;
                auto n = cast(uint) gy.data.length;
                Global.kernel!reluGrad
                    .call(gx.data.ptr, gy.data.ptr, this.dx.data.ptr, n).launch([1,1,1], [n,1,1]);
            }
            return gx;
        }
    }
}

unittest {
    import std.typecons;
    grain.autograd.backprop = true;
    scope (exit) grain.autograd.backprop = false;
    {
        auto func = new ReLU!(float, 1);
        auto x = [-1.0f, 2.0f, 3.0f].variable(true);
        auto y = func.applyForward(x);
        auto gy = [1.0f, 2.0f, 3.0f].variable;
        auto ugy = UntypedVariable(gy);
        y.backward(&ugy);
        assert(x.grad == [0, 2, 3]);

        auto func2 = new ReLU!(float, 1);
        auto y2 = func.applyForward(x);
        y2.backward(&ugy);
        assert(x.grad == [0, 4, 6]); // summation
    }
    version (grain_cuda) {
        auto func = new ReLU!(float, 1);
        auto x = [-1.0f, 2.0f, 3.0f].variable(true).to!DeviceStorage;
        auto y = func.applyForward(x);
        auto gy = [1.0f, 2.0f, 3.0f].variable.to!DeviceStorage;
        auto ugy = UntypedVariable(gy);
        y.backward(&ugy);
        assert(x.grad.toHost() == [0, 2, 3]);

        auto func2 = new ReLU!(float, 1);
        auto y2 = func.applyForward(x);
        y2.backward(&ugy);
        assert(x.grad.toHost() == [0, 4, 6]); // summation
    }
}


///
unittest {
    import grain.testing : gradCheck;
    foreach (inplace; [true, false]) {
        auto func = new ReLU!(float, 1);
        func.inplace = inplace;

        // test CPU
        {
            auto x = [-1.0f, 1.0f, 0.0f].variable;
            // gradCheck(func, x, [0.1f, 0.1f, 0.1f].variable);

            auto y = func.forward(x);
            assert(x.data == (inplace ? y.data : [-1.0f, 1.0f, 0.0f]));
            assert(y.data[0] == 0.0);
            assert(y.data[1] == 1.0);
            assert(y.data[2] == 0.0);
            // Why fail?
            // assert(y.data == [0.0f, 1.0f, 0.0f]);

            // x = [-1.0f, 1.0f, 0.0f].variable;
            // writeln(func.hx);
            auto gy = [1.0f, 2.0f, 3.0f].variable;
            auto gx = func.backward(gy);
            assert(gx.data[0] == 0.0);
            assert(gx.data[1] == 2.0);
            assert(gx.data[2] == 3.0);
        }

        // test CUDA
        version(grain_cuda) {
            auto x = [-1.0f, 1.0f, 0.0f].variable;
            auto xd = x.to!DeviceStorage;
            auto yd = func.forward(xd);
            x = xd.to!HostStorage;
            auto y = yd.to!HostStorage;
            assert(x.data == (inplace ? y.data : [-1.0f, 1.0f, 0.0f]));
            assert(y.data == [0.0f, 1.0f, 0.0f]);

            x = [-1.0f, 1.0f, 0.0f].variable;
            auto gy = [1.0f, 2.0f, 3.0f].variable;
            auto gxd = func.backward(gy.to!DeviceStorage);
            auto gx = gxd.to!HostStorage;
            import std.format;
            assert(gx.data == [0.0, 2.0, 0.0], format!"%s"(gx.data[]));
        }
    }
}

/++
 Matrix-Matrix multiplication

 See_Also: https://github.com/chainer/chainer/blob/v1/chainer/functions/connection/linear.py#L11
 +/
struct MatMul(T) {
    import mir.ndslice : transposed, universal;
    import std.typecons : tuple;
    import lubeck : mtimes;
    T alpha = 1;
    T beta = 0;
    Variable!(T, 2, HostStorage) ha, hb;

    // TODO uncomment this line
    mixin FunctionCommon;

    auto forward(Variable!(T, 2, HostStorage) a, Variable!(T, 2, HostStorage) b) {
        // TODO if training
        this.ha = a;
        this.hb = b;
        return mtimes(a.sliced, b.sliced).variable(a.requiresGrad || b.requiresGrad);
    }

    auto backward(Variable!(T, 2, HostStorage) gy) {
        auto ga = mtimes(gy.sliced, this.hb.sliced.transposed).variable;
        auto gb = mtimes(this.ha.sliced.transposed, gy.sliced).variable;
        return tuple(ga, gb);
    }

    version(grain_cuda) {
        Variable!(T, 2, DeviceStorage) da, db;

        auto forward(Variable!(T, 2, DeviceStorage) a, Variable!(T, 2, DeviceStorage) b) {
            import grain.cublas;
            static if (is(T == float)) {
                alias gemm = cublasSgemm_v2;
            } else static if (is(T == double)) {
                alias gemm = cublasDgemm_v2;
            } else {
                static assert(false, "unsupported type");
            }

            import std.typecons : RefCounted;
            assert(a.shape[1] == b.shape[0]);
            auto cdata = RefCounted!(CuPtr!T)(a.shape[0] * b.shape[1]);
            auto c = Variable!(T, 2, DeviceStorage)(
                false, [a.shape[0], b.shape[1]], [b.shape[1], 1], cdata);
            // C = A x B = (BT x AT)T
            // TODO support transposed (CUBLAS_OP_T)
            // see https://github.com/libmir/mir-blas/blob/master/source/mir/blas.d#L299
            // TODO if train
            this.da = a;
            this.db = b;
            checkCublasErrors(gemm(cublasHandle, CUBLAS_OP_N, CUBLAS_OP_N,
                                   cast(int) b.shape[1],
                                   cast(int) a.shape[0], cast(int) a.shape[1],
                                   &alpha,
                                   cast(const T*) b.data.ptr, cast(int) b.strides[0],
                                   cast(const T*) a.data.ptr, cast(int) a.strides[0],
                                   &beta,
                                   cast(T*) c.data.ptr, cast(int) c.strides[0]));
            return c;
        }

        auto backward(Variable!(T, 2, DeviceStorage) gc) {
            import grain.cublas;
            static if (is(T == float)) {
                alias gemm = cublasSgemm_v2;
            } else static if (is(T == double)) {
                alias gemm = cublasDgemm_v2;
            } else {
                static assert(false, "unsupported type");
            }
            auto ga = this.da.dup;
            auto gb = this.db.dup;
            // auto ga = mtimes(gc.sliced, this.hb.sliced.transposed).variable;
            checkCublasErrors(gemm(cublasHandle, CUBLAS_OP_T, CUBLAS_OP_N,
                                   cast(int) ga.shape[1],
                                   cast(int) ga.shape[0], cast(int) gc.shape[1],
                                   &alpha,
                                   cast(const T*) db.data.ptr, cast(int) db.strides[0],
                                   cast(const T*) gc.data.ptr, cast(int) gc.strides[0],
                                   &beta,
                                   cast(T*) ga.data.ptr, cast(int) ga.strides[0]));
            // auto gb = mtimes(this.ha.sliced.transposed, gc.sliced).variable;
            checkCublasErrors(gemm(cublasHandle, CUBLAS_OP_N, CUBLAS_OP_T,
                                   cast(int) gb.shape[1],
                                   cast(int) gb.shape[0], cast(int) da.shape[0],
                                   &alpha,
                                   cast(const T*) gc.data.ptr, cast(int) gc.strides[0],
                                   cast(const T*) da.data.ptr, cast(int) da.strides[0],
                                   &beta,
                                   cast(T*) gb.data.ptr, cast(int) gb.strides[0]));
            return tuple(ga, gb);
        }
    }
}

///
unittest {
    foreach (i; [2, 3, 4]) {
        foreach (j; [2, 3, 4]) {
            import std.typecons : tuple;
            import numir : uniform;
            import mir.ndslice : slice;
            import grain.testing;

            auto k = 3;
            auto a = uniform!float(i, k).slice.variable;
            auto b = uniform!float(k, j).slice.variable;
            auto gc = uniform!float(i, j).slice.variable;
            MatMul!float func;
            gradCheck(func, tuple(a, b), gc, 1e-3, 1e-3, 1e-3);

            version (grain_cuda) {
                import numir.testing;
                MatMul!float func2;
                auto hc = func.forward(a, b);
                auto dc = func2.forward(a.to!DeviceStorage, b.to!DeviceStorage);
                assert(approxEqual(dc.to!HostStorage.sliced, hc.sliced));
                auto hgab = func.backward(gc);
                auto dgab = func2.backward(gc.to!DeviceStorage);
                // writefln!"%s vs %s"(dgab[0].to!HostStorage.sliced, hgab[0].sliced);
                assert(approxEqual(dgab[0].to!HostStorage.sliced, hgab[0].sliced));
                assert(approxEqual(dgab[1].to!HostStorage.sliced, hgab[1].sliced));
            }
        }
    }
}

// TODO add to numir
import mir.ndslice : isSlice;
import numir : Ndim;
pure nothrow @nogc
logsumexp(S)(S x) if (isSlice!S && Ndim!S == 1) {
    import mir.ndslice : map, maxIndex;
    import mir.math : log, sum, exp;
    auto m = x[x.maxIndex];
    auto s = map!exp(x - m).sum!"fast".log;
    return m + s;
}

///
pure nothrow @nogc
unittest {
    import numir;
    import mir.ndslice;
    // import mir.math;
    import std.math;
    static immutable x = [-1.0, 2.0, 3.0];
    static immutable e = log(exp(-1.0) + exp(2.0) + exp(3.0));
    assert(approxEqual(x.sliced.logsumexp, e));
    static immutable xs = [-1.0, 2.0, 3.0,
                           -1.0, 2.0, 3.0,
                           -1.0, 2.0, 3.0];
    static immutable es = [e, e, e];
    assert(approxEqual(xs.sliced(3, 3).alongDim!1.map!logsumexp, es));
}

/++
See_also: https://github.com/chainer/chainer/blob/v1/chainer/functions/activation/log_softmax.py
 +/
struct LogSoftmax(T, size_t dim=2) {
    // TODO support custom dim to compute softmax over (now only dim=1)
     mixin FunctionCommon;

    Variable!(T, dim, HostStorage) hy;

    auto forward(Variable!(T, dim, HostStorage) x) {
        import mir.ndslice;
        import numir;
        // return slice(x.sliced.alongDim!0.map!(e => e - e.logsumexp)).variable;
        auto y = x.dup;
        foreach (i; 0 .. y.shape[0]) {
            y.sliced[i][] -= x.sliced[i].logsumexp;
        }
        // TODO if train
        this.hy = y;
        return y;
    }

    auto backward(Variable!(T, dim, HostStorage) gy) {
        import mir.math;
        import numir;
        import mir.ndslice;
        auto gx = gy.dup;
        auto m = gy.sliced.alongDim!1.map!(sum!"fast");
        foreach (i; 0 .. gx.shape[0]) {
            gx.sliced[i][] -= this.hy.sliced[i].map!exp * m[i];
        }
        return gx;
    }

    version (grain_cuda) {
        import grain.cudnn;
        Variable!(T, dim, DeviceStorage) dy;

        auto forward(Variable!(T, dim, DeviceStorage) x) {
            auto y = x.dup;
            softmaxForward!CUDNN_SOFTMAX_LOG(x, y);
            // TODO if train
            this.dy = y;
            return y;
        }

        auto backward(Variable!(T, dim, DeviceStorage) gy) {
            auto gx = gy.dup;
            softmaxBackward!CUDNN_SOFTMAX_LOG(gx, gy, this.dy);
            return gx;
        }
    }
}

///
unittest {
    import grain.testing;
    import std.typecons;
    import numir;
    import mir.ndslice;
    import mir.math;
    auto e = log(exp(-1.0) + exp(2.0) + exp(3.0));
    auto xs = [[-1.0f, 2.0f, 3.0f], [-1.0f, 2.0f, 3.0f], [-1.0f, 2.0f, 3.0f]].nparray;
    LogSoftmax!float hfunc;
    auto _hx = xs.variable;
    auto _hy = hfunc.forward(_hx);
    assert(approxEqual(_hy.sliced, xs - e));

    auto hx = uniform!float(2, 2).slice.variable;
    auto hy = hfunc.forward(hx);
    auto hgy = uniform!float(2, 2).slice.variable;
    auto hgx = hfunc.backward(hgy);
    gradCheck(hfunc, hx, hgy, 1e-3, 1e-3, 1e-3);

    version (grain_cuda) {
        alias Storage = DeviceStorage;
        auto func = LogSoftmax!float();
        auto dx = hx.to!Storage;
        auto dy = func.forward(dx);
        assert(approxEqual(dy.to!HostStorage.sliced, hy.sliced));
        auto dgy = hgy.to!Storage;
        auto dgx = func.backward(dgy);
        assert(approxEqual(dgx.to!HostStorage.sliced, hgx.sliced));
    }
}


struct NegativeLogLikelihood(F, I=long) {
    /++
    Compute negative log-likelihood: -logP(y=t)
    Params:
      logP: log softmax output as prediction. shape: (nBatch, nClass)
      targetId: target integer id of class. shape: (nBatch)
      +/

    bool sizeAverage = true;
    int ignoreIndex = -100;
    // TODO: bool reduce = true;

    // cache for backward
    Variable!(F, 2, HostStorage) _hlogP;
    Variable!(I, 1, HostStorage) _htargetId;
    F _normalize;

    Variable!(F, 0, HostStorage) forward(Variable!(F, 2, HostStorage) logP, Variable!(I, 1, HostStorage) targetId) {
        import mir.math;
        import mir.ndslice;
        F result = 0.0;
        size_t count = 0;
        foreach (i; 0 .. targetId.sliced.length) {
            auto t = targetId.sliced[i];
            if (t != ignoreIndex) {
                result -= logP.sliced[i, t];
                ++count;
            }
        }
        if (sizeAverage && count > 0) {
            result /= count;
        }
        // TODO if train
        this._hlogP = logP;
        this._htargetId = targetId;
        this._normalize = sizeAverage && count > 0 ? 1.0 / count : 1.0;
        return result.variable;
    }

    import std.typecons;
    Tuple!(Variable!(F, 2, HostStorage), Variable!(I, 1, HostStorage)) backward(Variable!(F, 0, HostStorage) gy) {
        import mir.math;
        import mir.ndslice;
        import numir;
        auto p = this._hlogP.sliced.map!exp;
        auto glogP = zeros_like(p);
        auto coeff = gy.data[0] * this._normalize;
        foreach (i; 0 .. this._htargetId.sliced.length) {
            auto t = this._htargetId.sliced[i];
            if (t != this.ignoreIndex) {
                glogP[i][t] = -coeff;
            }
        }
        return tuple(glogP.variable, typeof(this._htargetId)());
    }
}

///
unittest {
    /++ equivalent torch v0.4 code
     x = torch.FloatTensor([[0.2, 0.4, 0.4], [0.1,0.5,0.4]])
     x.requires_grad = True
     t = torch.LongTensor([1, 0])
     l = torch.nn.functional.nll_loss(x, t)
     print(l)       # tensor(-0.2500)
     l.backward()
     print(x.grad)  # tensor([[0.0, -0.5, 0.0], [-0.5, 0.0, 0.0]])
     +/
    import std.typecons;
    import grain.testing;
    NegativeLogLikelihood!(float, long) func;
    auto x = [[0.2f, 0.4f, 0.4f], [0.1f, 0.5f, 0.4f]].variable;
    auto t = [1L, 0L].variable;
    auto l = func.forward(x, t);
    assert(func._normalize == 0.5);
    assert(l.sliced == [-(0.4f + 0.1f) / 2]);
    auto gxs = func.backward(1.0f.variable);
    gradCheck(func, tuple(x, t), 1.0f.variable);
}
