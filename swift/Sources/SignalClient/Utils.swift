//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalFfi

internal func invokeFnReturningString(fn: (UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> SignalFfiErrorRef?) throws -> String {
    var output: UnsafePointer<Int8>?
    try checkError(fn(&output))
    let result = String(cString: output!)
    signal_free_string(output)
    return result
}

internal func invokeFnReturningArray(fn: (UnsafeMutablePointer<UnsafePointer<UInt8>?>?, UnsafeMutablePointer<Int>?) -> SignalFfiErrorRef?) throws -> [UInt8] {
    var output: UnsafePointer<UInt8>?
    var output_len = 0
    try checkError(fn(&output, &output_len))
    let result = Array(UnsafeBufferPointer(start: output, count: output_len))
    signal_free_buffer(output, output_len)
    return result
}

internal func invokeFnReturningInteger<Result: FixedWidthInteger>(fn: (UnsafeMutablePointer<Result>?) -> SignalFfiErrorRef?) throws -> Result {
    var output: Result = 0
    try checkError(fn(&output))
    return output
}

internal func invokeFnReturningPublicKey(fn: (UnsafeMutablePointer<OpaquePointer?>?) -> SignalFfiErrorRef?) throws -> PublicKey {
    var pk_handle: OpaquePointer?
    try checkError(fn(&pk_handle))
    return PublicKey(owned: pk_handle!)
}

internal func invokeFnReturningPrivateKey(fn: (UnsafeMutablePointer<OpaquePointer?>?) -> SignalFfiErrorRef?) throws -> PrivateKey {
    var pk_handle: OpaquePointer?
    try checkError(fn(&pk_handle))
    return PrivateKey(owned: pk_handle!)
}

internal func invokeFnReturningOptionalPublicKey(fn: (UnsafeMutablePointer<OpaquePointer?>?) -> SignalFfiErrorRef?) throws -> PublicKey? {
    var pk_handle: OpaquePointer?
    try checkError(fn(&pk_handle))
    return pk_handle.map { PublicKey(owned: $0) }
}

internal func invokeFnReturningCiphertextMessage(fn: (UnsafeMutablePointer<OpaquePointer?>?) -> SignalFfiErrorRef?) throws -> CiphertextMessage {
    var handle: OpaquePointer?
    try checkError(fn(&handle))
    return CiphertextMessage(owned: handle)
}

internal func withIdentityKeyStore<Result>(_ store: IdentityKeyStore, _ body: (UnsafePointer<SignalIdentityKeyStore>) throws -> Result) throws -> Result {
    func ffiShimGetIdentityKeyPair(store_ctx: UnsafeMutableRawPointer?,
                                   keyp: UnsafeMutablePointer<OpaquePointer?>?,
                                   ctx: UnsafeMutableRawPointer?) -> Int32 {
        do {
            let store = store_ctx!.assumingMemoryBound(to: IdentityKeyStore.self).pointee
            var privateKey = try store.identityKeyPair(context: ctx).privateKey
            keyp!.pointee = try cloneOrTakeHandle(from: &privateKey)
            return 0
        } catch {
            return -1
        }
    }

    func ffiShimGetLocalRegistrationId(store_ctx: UnsafeMutableRawPointer?,
                                       idp: UnsafeMutablePointer<UInt32>?,
                                       ctx: UnsafeMutableRawPointer?) -> Int32 {
        do {
            let store = store_ctx!.assumingMemoryBound(to: IdentityKeyStore.self).pointee
            let id = try store.localRegistrationId(context: ctx)
            idp!.pointee = id
            return 0
        } catch {
            return -1
        }
    }

    func ffiShimSaveIdentity(store_ctx: UnsafeMutableRawPointer?,
                             address: OpaquePointer?,
                             public_key: OpaquePointer?,
                             ctx: UnsafeMutableRawPointer?) -> Int32 {
        do {
            let store = store_ctx!.assumingMemoryBound(to: IdentityKeyStore.self).pointee
            var address = ProtocolAddress(borrowing: address)
            defer { cloneOrForgetAsNeeded(&address) }
            var public_key = PublicKey(borrowing: public_key)
            defer { cloneOrForgetAsNeeded(&public_key) }
            let identity = IdentityKey(publicKey: public_key)
            let new_id = try store.saveIdentity(identity, for: address, context: ctx)
            if new_id {
                return 1
            } else {
                return 0
            }
        } catch {
            return -1
        }
    }

    func ffiShimGetIdentity(store_ctx: UnsafeMutableRawPointer?,
                            public_key: UnsafeMutablePointer<OpaquePointer?>?,
                            address: OpaquePointer?,
                            ctx: UnsafeMutableRawPointer?) -> Int32 {
        do {
            let store = store_ctx!.assumingMemoryBound(to: IdentityKeyStore.self).pointee
            var address = ProtocolAddress(borrowing: address)
            defer { cloneOrForgetAsNeeded(&address) }
            if let pk = try store.identity(for: address, context: ctx) {
                var publicKey = pk.publicKey
                public_key!.pointee = try cloneOrTakeHandle(from: &publicKey)
            } else {
                public_key!.pointee = nil
            }
            return 0
        } catch {
            return -1
        }
    }

    func ffiShimIsTrustedIdentity(store_ctx: UnsafeMutableRawPointer?,
                                  address: OpaquePointer?,
                                  public_key: OpaquePointer?,
                                  raw_direction: UInt32,
                                  ctx: UnsafeMutableRawPointer?) -> Int32 {
        do {
            let store = store_ctx!.assumingMemoryBound(to: IdentityKeyStore.self).pointee
            var address = ProtocolAddress(borrowing: address)
            defer { cloneOrForgetAsNeeded(&address) }
            var public_key = PublicKey(borrowing: public_key)
            defer { cloneOrForgetAsNeeded(&public_key) }
            let direction: Direction
            switch SignalDirection(raw_direction) {
            case SignalDirection_Sending:
                direction = .sending
            case SignalDirection_Receiving:
                direction = .receiving
            default:
                assertionFailure("unexpected direction value")
                return -1
            }
            let identity = IdentityKey(publicKey: public_key)
            let trusted = try store.isTrustedIdentity(identity, for: address, direction: direction, context: ctx)
            return trusted ? 1 : 0
        } catch {
            return -1
        }
    }

    return try withUnsafePointer(to: store) {
        // We're not actually going to mutate through 'ffiStore.ctx';
        // it's just the usual convention of `void *` for context fields.
        var ffiStore = SignalIdentityKeyStore(
            ctx: UnsafeMutableRawPointer(mutating: $0),
            get_identity_key_pair: ffiShimGetIdentityKeyPair,
            get_local_registration_id: ffiShimGetLocalRegistrationId,
            save_identity: ffiShimSaveIdentity,
            get_identity: ffiShimGetIdentity,
            is_trusted_identity: ffiShimIsTrustedIdentity)
        return try body(&ffiStore)
    }
}

internal func withPreKeyStore<Result>(_ store: PreKeyStore, _ body: (UnsafePointer<SignalPreKeyStore>) throws -> Result) throws -> Result {
    func ffiShimStorePreKey(store_ctx: UnsafeMutableRawPointer?,
                            id: UInt32,
                            record: OpaquePointer?,
                            ctx: UnsafeMutableRawPointer?) -> Int32 {
        do {
            let store = store_ctx!.assumingMemoryBound(to: PreKeyStore.self).pointee
            var record = PreKeyRecord(borrowing: record)
            defer { cloneOrForgetAsNeeded(&record) }
            try store.storePreKey(record, id: id, context: ctx)
            return 0
        } catch {
            return -1
        }
    }

    func ffiShimLoadPreKey(store_ctx: UnsafeMutableRawPointer?,
                           recordp: UnsafeMutablePointer<OpaquePointer?>?,
                           id: UInt32,
                           ctx: UnsafeMutableRawPointer?) -> Int32 {
        do {
            let store = store_ctx!.assumingMemoryBound(to: PreKeyStore.self).pointee
            var record = try store.loadPreKey(id: id, context: ctx)
            recordp!.pointee = try cloneOrTakeHandle(from: &record)
            return 0
        } catch {
            return -1
        }
    }

    func ffiShimRemovePreKey(store_ctx: UnsafeMutableRawPointer?,
                             id: UInt32,
                             ctx: UnsafeMutableRawPointer?) -> Int32 {
        do {
            let store = store_ctx!.assumingMemoryBound(to: PreKeyStore.self).pointee
            try store.removePreKey(id: id, context: ctx)
            return 0
        } catch {
            return -1
        }
    }

    return try withUnsafePointer(to: store) {
        // We're not actually going to mutate through 'ffiStore.ctx';
        // it's just the usual convention of `void *` for context fields.
        var ffiStore = SignalPreKeyStore(
            ctx: UnsafeMutableRawPointer(mutating: $0),
            load_pre_key: ffiShimLoadPreKey,
            store_pre_key: ffiShimStorePreKey,
            remove_pre_key: ffiShimRemovePreKey)
        return try body(&ffiStore)
    }
}

internal func withSignedPreKeyStore<Result>(_ store: SignedPreKeyStore, _ body: (UnsafePointer<SignalSignedPreKeyStore>) throws -> Result) throws -> Result {
    func ffiShimStoreSignedPreKey(store_ctx: UnsafeMutableRawPointer?,
                                  id: UInt32,
                                  record: OpaquePointer?,
                                  ctx: UnsafeMutableRawPointer?) -> Int32 {
        do {
            let store = store_ctx!.assumingMemoryBound(to: SignedPreKeyStore.self).pointee
            var record = SignedPreKeyRecord(borrowing: record)
            defer { cloneOrForgetAsNeeded(&record) }
            try store.storeSignedPreKey(record, id: id, context: ctx)
            return 0
        } catch {
            return -1
        }
    }

    func ffiShimLoadSignedPreKey(store_ctx: UnsafeMutableRawPointer?,
                                 recordp: UnsafeMutablePointer<OpaquePointer?>?,
                                 id: UInt32,
                                 ctx: UnsafeMutableRawPointer?) -> Int32 {
        do {
            let store = store_ctx!.assumingMemoryBound(to: SignedPreKeyStore.self).pointee
            var record = try store.loadSignedPreKey(id: id, context: ctx)
            recordp!.pointee = try cloneOrTakeHandle(from: &record)
            return 0
        } catch {
            return -1
        }
    }

    return try withUnsafePointer(to: store) {
        // We're not actually going to mutate through 'ffiStore.ctx';
        // it's just the usual convention of `void *` for context fields.
        var ffiStore = SignalSignedPreKeyStore(
            ctx: UnsafeMutableRawPointer(mutating: $0),
            load_signed_pre_key: ffiShimLoadSignedPreKey,
            store_signed_pre_key: ffiShimStoreSignedPreKey)
        return try body(&ffiStore)
    }
}

internal func withSessionStore<Result>(_ store: SessionStore, _ body: (UnsafePointer<SignalSessionStore>) throws -> Result) throws -> Result {
    func ffiShimStoreSession(store_ctx: UnsafeMutableRawPointer?,
                             address: OpaquePointer?,
                             record: OpaquePointer?,
                             ctx: UnsafeMutableRawPointer?) -> Int32 {
        do {
            let store = store_ctx!.assumingMemoryBound(to: SessionStore.self).pointee
            var address = ProtocolAddress(borrowing: address)
            defer { cloneOrForgetAsNeeded(&address) }
            var record = SessionRecord(borrowing: record)
            defer { cloneOrForgetAsNeeded(&record) }
            try store.storeSession(record, for: address, context: ctx)
            return 0
        } catch {
            return -1
        }
    }

    func ffiShimLoadSession(store_ctx: UnsafeMutableRawPointer?,
                            recordp: UnsafeMutablePointer<OpaquePointer?>?,
                            address: OpaquePointer?,
                            ctx: UnsafeMutableRawPointer?) -> Int32 {
        do {
            let store = store_ctx!.assumingMemoryBound(to: SessionStore.self).pointee
            var address = ProtocolAddress(borrowing: address)
            defer { cloneOrForgetAsNeeded(&address) }
            if var record = try store.loadSession(for: address, context: ctx) {
                recordp!.pointee = try cloneOrTakeHandle(from: &record)
            } else {
                recordp!.pointee = nil
            }
            return 0
        } catch {
            return -1
        }
    }

    return try withUnsafePointer(to: store) {
        // We're not actually going to mutate through 'ffiStore.ctx';
        // it's just the usual convention of `void *` for context fields.
        var ffiStore = SignalSessionStore(
            ctx: UnsafeMutableRawPointer(mutating: $0),
            load_session: ffiShimLoadSession,
            store_session: ffiShimStoreSession)
        return try body(&ffiStore)
    }
}

internal func withSenderKeyStore<Result>(_ store: SenderKeyStore, _ body: (UnsafePointer<SignalSenderKeyStore>) throws -> Result) rethrows -> Result {
    func ffiShimStoreSenderKey(store_ctx: UnsafeMutableRawPointer?,
                               sender_name: OpaquePointer?,
                               record: OpaquePointer?,
                               ctx: UnsafeMutableRawPointer?) -> Int32 {
        do {
            let store = store_ctx!.assumingMemoryBound(to: SenderKeyStore.self).pointee
            var sender_name = SenderKeyName(borrowing: sender_name)
            defer { cloneOrForgetAsNeeded(&sender_name) }
            var record = SenderKeyRecord(borrowing: record)
            defer { cloneOrForgetAsNeeded(&record) }
            try store.storeSenderKey(name: sender_name, record: record, context: ctx)
            return 0
        } catch {
            return -1
        }
    }

    func ffiShimLoadSenderKey(store_ctx: UnsafeMutableRawPointer?,
                              recordp: UnsafeMutablePointer<OpaquePointer?>?,
                              sender_name: OpaquePointer?,
                              ctx: UnsafeMutableRawPointer?) -> Int32 {
        do {
            let store = store_ctx!.assumingMemoryBound(to: SenderKeyStore.self).pointee
            var sender_name = SenderKeyName(borrowing: sender_name)
            defer { cloneOrForgetAsNeeded(&sender_name) }
            if var record = try store.loadSenderKey(name: sender_name, context: ctx) {
                recordp!.pointee = try cloneOrTakeHandle(from: &record)
            } else {
                recordp!.pointee = nil
            }
            return 0
        } catch {
            return -1
        }
    }

    return try withUnsafePointer(to: store) {
        // We're not actually going to mutate through 'ffiStore.ctx';
        // it's just the usual convention of `void *` for context fields.
        var ffiStore = SignalSenderKeyStore(
            ctx: UnsafeMutableRawPointer(mutating: $0),
            load_sender_key: ffiShimLoadSenderKey,
            store_sender_key: ffiShimStoreSenderKey)
        return try body(&ffiStore)
    }
}
