extension Platform {
    /// What a process does to itself, and the images it starts: sealed in-memory copies (SealedCopy.swift), so
    /// that a file changed on disk after it was loaded is never what runs, and a child started from one is
    /// non-dumpable from its exec.
    public enum ProcessSelf {}
}
