# Runnable collaboration example

Run the offline collaboration walkthrough from the module root:

```sh
moon run --target native examples
```

The program shows Alice and Bob editing local documents, transferring a full
versioned update to initialize a peer, sending incremental encoded updates in
both directions, and grouping related map and text changes in an observed
transaction. It also syncs a semantic undo and redo, then saves and restores a
document through an in-memory PersistenceAdapter. It prints update sizes, the
restored text, and the converged replica state.

The encoded bytes use Y.mbt's own versioned format. Applications can store or
transport those bytes through their own adapters; the core does not open a
network connection or choose a persistent storage backend. The in-memory
adapter is only a small example of the callback boundary.
