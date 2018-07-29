include(joinpath("..","deps","kspec.jl"))

# use our own random seed for msg_id so that we
# don't alter the user-visible random state (issue #336)
const IJulia_RNG = Random.srand(Random.MersenneTwister(0))
@static if VERSION < v"0.7.0-DEV.3666" # julia#25819
    uuid4() = repr(Random.uuid4(IJulia_RNG))
else
    import UUIDs
    uuid4() = repr(UUIDs.uuid4(IJulia_RNG))
end

if VERSION < v"0.7.0-DEV.4445" # julia#26130
    run(args...; wait=nothing) = wait === false ?
        Base.spawn(args...) : Base.run(args...)
end

const orig_stdin  = Ref{IO}()
const orig_stdout = Ref{IO}()
const orig_stderr = Ref{IO}()
function __init__()
    Random.srand(IJulia_RNG)
    orig_stdin[]  = stdin
    orig_stdout[] = stdout
    orig_stderr[] = stderr
end

# the following constants need to be initialized in init().
const ctx = Ref{Context}()
const publish = Ref{Socket}()
const raw_input = Ref{Socket}()
const requests = Ref{Socket}()
const control = Ref{Socket}()
const heartbeat = Ref{Socket}()
const profile = Dict{String,Any}()
const read_stdout = Ref{Base.PipeEndpoint}()
const read_stderr = Ref{Base.PipeEndpoint}()
const socket_locks = Dict{Socket,ReentrantLock}()

function qtconsole()
    if inited
        run(`$jupyter qtconsole --existing $connection_file`; wait=false)
    else
        error("IJulia is not running. qtconsole must be called from an IJulia session.")
    end
end

function init(args)
    inited && error("IJulia is already running")
    if length(args) > 0
        merge!(profile, open(JSON.parse,args[1]))
        verbose && println("PROFILE = $profile")
        global connection_file = args[1]
    else
        # generate profile and save
        let port0 = 5678
            merge!(profile, Dict{String,Any}(
                "ip" => "127.0.0.1",
                "transport" => "tcp",
                "stdin_port" => port0,
                "control_port" => port0+1,
                "hb_port" => port0+2,
                "shell_port" => port0+3,
                "iopub_port" => port0+4,
                "key" => uuid4()
            ))
            fname = "profile-$(getpid()).json"
            global connection_file = "$(pwd())/$fname"
            println("connect ipython with --existing $connection_file")
            open(fname, "w") do f
                JSON.print(f, profile)
            end
        end
    end

    if !isempty(profile["key"])
        signature_scheme = get(profile, "signature_scheme", "hmac-sha256")
        isempty(signature_scheme) && (signature_scheme = "hmac-sha256")
        sigschm = split(signature_scheme, "-")
        if sigschm[1] != "hmac" || length(sigschm) != 2
            error("unrecognized signature_scheme $signature_scheme")
        end
        hmacstate[] = MbedTLS.MD(getfield(MbedTLS, Symbol("MD_", uppercase(sigschm[2]))),
                                 profile["key"])
    end

    ctx[] = Context()
    publish[] = Socket(ctx[], PUB)
    raw_input[] = Socket(ctx[], ROUTER)
    requests[] = Socket(ctx[], ROUTER)
    control[] = Socket(ctx[], ROUTER)
    heartbeat[] = Socket(ctx[], ROUTER)
    bind(publish[], "$(profile["transport"])://$(profile["ip"]):$(profile["iopub_port"])")
    bind(requests[], "$(profile["transport"])://$(profile["ip"]):$(profile["shell_port"])")
    bind(control[], "$(profile["transport"])://$(profile["ip"]):$(profile["control_port"])")
    bind(raw_input[], "$(profile["transport"])://$(profile["ip"]):$(profile["stdin_port"])")
    bind(heartbeat[], "$(profile["transport"])://$(profile["ip"]):$(profile["hb_port"])")

    # associate a lock with each socket so that multi-part messages
    # on a given socket don't get inter-mingled between tasks.
    for s in (publish[], raw_input[], requests[], control[], heartbeat[])
        socket_locks[s] = ReentrantLock()
    end

    start_heartbeat(heartbeat[])
    if capture_stdout
        read_stdout[], = redirect_stdout()
        redirect_stdout(IJuliaStdio(stdout,"stdout"))
    end
    if capture_stderr
        read_stderr[], = redirect_stderr()
        redirect_stderr(IJuliaStdio(stderr,"stderr"))
    end
    redirect_stdin(IJuliaStdio(stdin,"stdin"))

    if isdefined(Base, :CoreLogging)
        logger = Base.CoreLogging.SimpleLogger(Base.stderr)
        Base.CoreLogging.global_logger(logger)
    end

    send_status("starting")
    global inited = true
end
