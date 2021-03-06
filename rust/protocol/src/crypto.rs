//
// Copyright 2020 Signal Messenger, LLC.
// SPDX-License-Identifier: AGPL-3.0-only
//

use crate::{error::Result, SignalProtocolError};

use aes::Aes256;
use block_modes::{block_padding::Pkcs7, BlockMode, Cbc};
use hmac::{Hmac, Mac, NewMac};
use sha2::Sha256;

pub fn aes_256_cbc_encrypt(ptext: &[u8], key: &[u8], iv: &[u8]) -> Result<Vec<u8>> {
    match Cbc::<Aes256, Pkcs7>::new_var(key, iv) {
        Ok(mode) => Ok(mode.encrypt_vec(&ptext)),
        Err(block_modes::InvalidKeyIvLength) => Err(
            SignalProtocolError::InvalidCipherCryptographicParameters(key.len(), iv.len()),
        ),
    }
}

pub fn aes_256_cbc_decrypt(ctext: &[u8], key: &[u8], iv: &[u8]) -> Result<Vec<u8>> {
    if ctext.is_empty() || ctext.len() % 16 != 0 {
        return Err(SignalProtocolError::InvalidCiphertext);
    }

    let mode = match Cbc::<Aes256, Pkcs7>::new_var(key, iv) {
        Ok(mode) => mode,
        Err(block_modes::InvalidKeyIvLength) => {
            return Err(SignalProtocolError::InvalidCipherCryptographicParameters(
                key.len(),
                iv.len(),
            ))
        }
    };

    Ok(mode
        .decrypt_vec(ctext)
        .map_err(|_| SignalProtocolError::InvalidCiphertext)?)
}

pub fn hmac_sha256(key: &[u8], input: &[u8]) -> Result<[u8; 32]> {
    let mut hmac = Hmac::<Sha256>::new_varkey(key).expect("HMAC-SHA256 should accept any size key");
    hmac.update(input);
    Ok(hmac.finalize().into_bytes().into())
}

#[cfg(test)]
mod test {

    #[test]
    fn aes_cbc_test() {
        let key = hex::decode("4e22eb16d964779994222e82192ce9f747da72dc4abe49dfdeeb71d0ffe3796e")
            .unwrap();
        let iv = hex::decode("6f8a557ddc0a140c878063a6d5f31d3d").unwrap();

        let ptext = hex::decode("30736294a124482a4159").unwrap();

        let ctext = super::aes_256_cbc_encrypt(&ptext, &key, &iv).unwrap();
        assert_eq!(
            hex::encode(ctext.clone()),
            "dd3f573ab4508b9ed0e45e0baf5608f3"
        );

        let recovered = super::aes_256_cbc_decrypt(&ctext, &key, &iv).unwrap();
        assert_eq!(hex::encode(ptext), hex::encode(recovered.clone()));

        // padding is invalid:
        assert!(super::aes_256_cbc_decrypt(&recovered, &key, &iv).is_err());
        assert!(super::aes_256_cbc_decrypt(&ctext, &key, &ctext).is_err());

        // bitflip the IV to cause a change in the recovered text
        let bad_iv = hex::decode("ef8a557ddc0a140c878063a6d5f31d3d").unwrap();
        let recovered = super::aes_256_cbc_decrypt(&ctext, &key, &bad_iv).unwrap();
        assert_eq!(hex::encode(recovered), "b0736294a124482a4159");
    }
}
