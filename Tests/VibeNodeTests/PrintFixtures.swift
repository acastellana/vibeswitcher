import Foundation

/// `launchctl print` of a job of the node's key set, cut from this Mac's captures (macOS 27.2, scratch jobs, the design's
/// "The re-check's round", measured): only the job's own values are placeholders, `{…}`, filled by `MacAgentTests.printed`.
enum PrintFixtures {
    static let running = """
        {TARGET} = {
        \tactive count = 1
        \tpath = {PLIST}
        \ttype = LaunchAgent
        \tstate = running
        
        \tprogram = {PROGRAM}
        \targuments = {
        {ARGUMENTS}\t}
        
        \tstdout path = /dev/null
        \tstderr path = {STDERR}
        \tinherited environment = {
        \t\tSSH_AUTH_SOCK => /var/run/com.apple.launchd.XXXXXXXXXX/Listeners
        \t}
        
        \tdefault environment = {
        \t\tPATH => /usr/bin:/bin:/usr/sbin:/sbin
        \t}
        
        \tenvironment = {
        {ENVIRONMENT}\t}
        
        \tdomain = gui/{UID} [100020]
        \tasid = 100020
        \tminimum runtime = 10
        \texit timeout = 5
        \truns = 1
        \tpid = {PID}
        \timmediate reason = non-ipc demand
        \tforks = 0
        \texecs = 1
        \tinitialized = 1
        \ttrampolined = 1
        \tstarted suspended = 0
        \tproxy started suspended = 0
        \tchecked allocations = 0 (queried = 1)
        \tchecked allocations reason = no host
        \tchecked allocations flags = 0x0
        \tlast exit code = (never exited)
        
        \tresource coalition = {
        \t\tID = 229261
        \t\ttype = resource
        \t\tstate = active
        \t\tactive count = 1
        \t\tname = {LABEL}
        \t}
        
        \tjetsam coalition = {
        \t\tID = 229262
        \t\ttype = jetsam
        \t\tstate = active
        \t\tactive count = 1
        \t\tname = {LABEL}
        \t}
        
        \tspawn type = interactive (4)
        \tjetsam priority = 40
        \tjetsam memory limit (active) = (unlimited)
        \tjetsam memory limit (inactive) = (unlimited)
        \tjetsamproperties category = daemon
        \tjetsam thread limit = 32
        \tcpumon = default
        \tsanitizer flags = 0x0
        
        \tproperties = inferred program
        }
        """
    static let loaded = """
        {TARGET} = {
        \tactive count = 0
        \tpath = {PLIST}
        \ttype = LaunchAgent
        \tstate = not running
        
        \tprogram = {PROGRAM}
        \targuments = {
        {ARGUMENTS}\t}
        
        \tstdout path = /dev/null
        \tstderr path = {STDERR}
        \tinherited environment = {
        \t\tSSH_AUTH_SOCK => /var/run/com.apple.launchd.XXXXXXXXXX/Listeners
        \t}
        
        \tdefault environment = {
        \t\tPATH => /usr/bin:/bin:/usr/sbin:/sbin
        \t}
        
        \tenvironment = {
        {ENVIRONMENT}\t}
        
        \tdomain = gui/{UID} [100020]
        \tasid = 100020
        \tminimum runtime = 10
        \texit timeout = 5
        \truns = 0
        \tlast exit code = (never exited)
        
        \tspawn type = interactive (4)
        \tjetsam priority = 40
        \tjetsam memory limit (active) = (unlimited)
        \tjetsam memory limit (inactive) = (unlimited)
        \tjetsamproperties category = daemon
        \tjetsam thread limit = 32
        \tcpumon = default
        \tsanitizer flags = 0x0
        
        \tproperties = inferred program
        }
        """
    static let killed = """
        {TARGET} = {
        \tactive count = 0
        \tpath = {PLIST}
        \ttype = LaunchAgent
        \tstate = not running
        
        \tprogram = {PROGRAM}
        \targuments = {
        {ARGUMENTS}\t}
        
        \tstdout path = /dev/null
        \tstderr path = {STDERR}
        \tinherited environment = {
        \t\tSSH_AUTH_SOCK => /var/run/com.apple.launchd.XXXXXXXXXX/Listeners
        \t}
        
        \tdefault environment = {
        \t\tPATH => /usr/bin:/bin:/usr/sbin:/sbin
        \t}
        
        \tenvironment = {
        {ENVIRONMENT}\t}
        
        \tdomain = gui/{UID} [100020]
        \tasid = 100020
        \tminimum runtime = 10
        \texit timeout = 5
        \truns = 1
        \tlast terminating signal = Killed: 9
        
        \tresource coalition = {
        \t\tID = 229261
        \t\ttype = resource
        \t\tstate = active
        \t\tactive count = 1
        \t\tname = {LABEL}
        \t}
        
        \tjetsam coalition = {
        \t\tID = 229262
        \t\ttype = jetsam
        \t\tstate = active
        \t\tactive count = 1
        \t\tname = {LABEL}
        \t}
        
        \tspawn type = interactive (4)
        \tjetsam priority = 40
        \tjetsam memory limit (active) = (unlimited)
        \tjetsam memory limit (inactive) = (unlimited)
        \tjetsamproperties category = daemon
        \tjetsam thread limit = 32
        \tcpumon = default
        \tsanitizer flags = 0x0
        
        \tproperties = inferred program
        }
        """
}
