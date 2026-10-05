///|
/// A storage callback failure or an error while encoding/decoding a stored
/// native update.
pub(all) enum AdapterError {
  StorageFailure(String)
  CrdtFailure(CrdtError)
} derive(Debug)

///|
/// A provider-supplied persistence boundary. The library does not choose a
/// filesystem, database, or browser storage implementation.
struct PersistenceAdapter {
  load_bytes : () -> Result[Bytes?, String]
  save_bytes : (Bytes) -> Result[Unit, String]
}

///|
/// Construct a persistence adapter from application-owned load and save
/// operations. `None` from `load_bytes` means that no saved document exists.
pub fn PersistenceAdapter::new(
  load_bytes : () -> Result[Bytes?, String],
  save_bytes : (Bytes) -> Result[Unit, String],
) -> PersistenceAdapter {
  { load_bytes, save_bytes, }
}

///|
/// Save a self-contained encoded update that can restore the current
/// document, including its checkpoint when it has been compacted.
pub fn Document::persist(
  self : Document,
  adapter : PersistenceAdapter,
) -> Result[Unit, AdapterError] {
  let update = match self.full_update() {
    Err(error) => return Err(CrdtFailure(error))
    Ok(update) => update
  }
  let bytes = match update.encode() {
    Err(error) => return Err(CrdtFailure(error))
    Ok(bytes) => bytes
  }
  match (adapter.save_bytes)(bytes) {
    Err(error) => Err(StorageFailure(error))
    Ok(_) => Ok(())
  }
}

///|
/// Restore a document from the adapter's latest self-contained update. An
/// empty store creates a fresh document for `replica`.
pub fn Document::restore(
  replica : String,
  adapter : PersistenceAdapter,
) -> Result[Document, AdapterError] {
  let bytes = match (adapter.load_bytes)() {
    Err(error) => return Err(StorageFailure(error))
    Ok(None) =>
      match Document::new(replica) {
        Err(error) => return Err(CrdtFailure(error))
        Ok(document) => return Ok(document)
      }
    Ok(Some(bytes)) => bytes
  }
  let update = match Update::decode(bytes) {
    Err(error) => return Err(CrdtFailure(error))
    Ok(update) => update
  }
  let document = match Document::new(replica) {
    Err(error) => return Err(CrdtFailure(error))
    Ok(document) => document
  }
  match document.apply_update(update) {
    Err(error) => Err(CrdtFailure(error))
    Ok(_) => Ok(document)
  }
}

///|
/// Produce an encoded incremental update for a provider to send to a peer.
/// The provider exchanges `state_vector()` metadata separately and remains
/// responsible for delivery, retries, and authentication.
pub fn Document::sync_update(
  self : Document,
  peer : StateVector,
) -> Result[Bytes, CrdtError] {
  match self.update_since(peer) {
    Err(error) => Err(error)
    Ok(update) => update.encode()
  }
}

///|
/// Decode and atomically apply one provider-delivered native sync payload.
pub fn Document::apply_sync_update(
  self : Document,
  encoded : Bytes,
) -> Result[ChangeSet, CrdtError] {
  match Update::decode(encoded) {
    Err(error) => Err(error)
    Ok(update) => self.apply_update(update)
  }
}
