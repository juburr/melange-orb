#!/bin/bash

set -e

# Ensure CircleCI environment variables can be passed in as orb parameters
INSTALL_PATH=$(circleci env subst "${PARAM_INSTALL_PATH}")
VERIFY_CHECKSUMS="${PARAM_VERIFY_CHECKSUMS}"
VERSION=$(circleci env subst "${PARAM_VERSION}")

# Print command arguments for debugging purposes.
echo "Running Melange installer..."
echo "  INSTALL_PATH: ${INSTALL_PATH}"
echo "  VERIFY_CHECKSUMS: ${VERIFY_CHECKSUMS}"
echo "  VERSION: ${VERSION}"

# Lookup table of sha512 checksums for different versions of melange
declare -A sha512sums
sha512sums=(
    ["0.12.1"]="57cf09c3871fcf76ebf75ff14b95f166bcc679c738f6428679250a68b0db7d2c6b83f2bdcbabd7f3a87a3bf389625789ad28517e9bfc5458c3443823514fbeac"
    ["0.12.0"]="a78d3dd062d1aca518ecc1d6d15cc74922c8d9b59903c485c3216845e1d46efae989da5e2ef5a479a88817d8b40dc50132e394e61558fe63af18f9ea3366d128"
    ["0.11.6"]="bab86120ff5f79a7f1dbf045db8522c0d015bb147d04fc738aa5f221b79f1386382231163e97c50bc9dddfcdd05f42723b29e4e43cc8eab5cfe7d8a73392aa91"
    ["0.11.5"]="280e510ff07d7f7fbb7af54e5d822d324d01b294d8b09d652f51fc6d1824b585f71ca7f25d53bda891d2b2b45207c12c83d8a5ec32722b6be21bd70e206fb688"
    ["0.11.4"]="82cb14dfa91b8b8c07890cf444a4e9b56d740e7114095cf7e2e560291946c97312bdaaa87711bcbbf4ec2ce1b6dc36536d2a191f2c158fd041a2b007c946d9e6"
    ["0.11.3"]="5b91eca33cbbb9c10c435e5775eb4511ffddeecb3da606229903ace111e363bec9996c2e8e9b10195e9fa12f6e3219854e5e195d1205578aeb03155828a64041"
    ["0.11.2"]="bfe52365ef73554b0e88490ce9219ee9cf509ae807e7ab8bd5bf3fd75862b26a527b45c8ab12d4f653fd6ea0df6a10b6812eb462cd641c99a6faa633faad80fa"
    ["0.11.1"]="247ff5cf7ddf91140359c98102f98c62d2927fdcdc58ba53f9fc6dc15d38c5b8bb9fb54cf29b5194897be009c592711e712a6f21a976538ec729fd6db7ae6ef7"
    ["0.11.0"]="17f9dca8e61e980ce5dff78c1c0298ee5a0df3cac47971f73f56d90b3e0b898d60a992c773a1ca295552a75e5a576578a5c79a9b9041bc957da790f0420ac786"
    ["0.10.4"]="d27c9505e08ce43aed65b164f7942dfd8c70a03cc3a137ec7621582b94888c203201e4376b67fdb574fafa003fd31bed99c0aba63a8fcac53ae1e01debc5d72d"
    ["0.10.3"]="27d2f52a7c64f52677f05951e90e12d5d06eace88d350b5beeab505c42d26d18867d93ccc9d9fa051b8ed85552e3c54f12f2c4734cfff9c137b881453cc795fa"
    ["0.10.2"]="28d4b7bb1978f7e79577857d8959de2dde60a455eb67e2957fd99496800857f2fffb6ca23c4e11d77fb383162046f610c4ac377c6ce6d120c7f969e737cccee9"
    ["0.10.1"]="1f3a022c54d597ab2c5b42067bc00a6476d70060a66b73cb52b5cce40bd2228babaecfa7f5b59edd4e394874294da975eb66a58ba4d09b95a855d322814945c9"
    ["0.10.0"]="3cceffe785300ebaf3a41c9c71a249c741c80d09766c7f55130e98ea6927d3260a9e49b454410077d5f40a65ddad06433e100284bcb9160db856698bc9f9cb20"
    ["0.9.0"]="887f5e6fd4db2bc9a1202236c968c363a91c3bf1996ea3a9b57f91f5cbfdff1c9288a2af8c58eaa1851ba0aa252fcc7582d3e01176f7a5d5abd723fa7f981ac9"
    ["0.8.6"]="c47277c0a07b7d1bb858beece76f61a25b5eb3f3f11f0e04a000f35c50b3279aa6677d1a69a3b0165b6b07f5aeb7a3d26d5b2fcaca1d9ca1dd91c23d3a26c644"
    ["0.8.5"]="3af79f4eefc5e6d70254db4bbaf9d4fd6266456b25785df23abd614ee9a27798201d6e3d6a8f4add9a8a264052ae6592e90a0c00b067d6173beaf0e6bf415b10"
    ["0.8.4"]="403b271f5f8a22103e0cef834656f7897ee2e5d8aa8525ed1af7993d0934224013bfeb344b57a8add331e0df77cfa15484aea2f047c0ebc9accee185a6c9d62a"
    ["0.8.3"]="8722c0694b63e8c093a3f55f26f783a95f2ec0c6a4901af92512bed1fc942fb7b31f30f504e434cb1eec39fcbf994e55b4587dcdaa77403f41fa58d084f17801"
    ["0.8.2"]="602e77f7f033ef1751b4f08a174ee8d8dbd2a11269520f9548b802d4b1d59ba8db6e2cb41c337fdef4d89fcfca45ef39d040c29382bcaae19812893b9769f40d"
    ["0.8.1"]="3c9c7369747605c0c1acbbe33a591b74299bc7aba420bb2e52bfa9030f08b69aa29edb35e151e38fb3da93594a5b47811494d6f869c62347ae53a5c3d3f1d552"
    ["0.8.0"]="4985bbae2b97412123b21eee7334d55deb88d7a4597b29fd7c4e65f58713a8f1cb3269d4ca184cfdfdd7d2a92a315068049ee0b160c288cc3f971db8b1f5fd37"
    ["0.7.0"]="fce4d2ec87012c18c9d251148bcd0cd318a87e9642cc1120977c56cfbe1e31d81062fbac0d4276004ffbb5f09c2cf7d75a0c6012f7827b834c28ac3b8afa8e4b"
    ["0.6.11"]="f5d799639b91def79a8d73a6720609789d92845de311d2bbb38b8d3fa344936c70b7a0a11bf48dbbcb59b5f458ee430481c95007bcaa2c0d834df95631eb4fdb"
    ["0.6.10"]="3ae4965abc312dd95b955e5155ccd9bf646c60e36756ddb3579e2d7b6ac81ff339dfa9d6754eb381a41ca185b47dc9688fef4d537c70791d205a14fcce7ebfca"
    ["0.6.9"]="f47d3a91155b4ea2269c37611207717539afab576b2d9268284f456c02142d8f0078319c667d88a2480d61f704a70740bd1c5865af22ec0f28e1bb139483ee16"
    ["0.6.8"]="419f08728e109ec2f52f55bb2908d7bdeb60db5757dd91e2472060f89291293728cadfc0d92081e16b829f1442e12ae3187dd6c9add0d8e8bd4dc42242cf1fb2"
    ["0.6.7"]="a18d929253357d9189c4dcdce51309b716c2690027156a346bf5642e3d8df3a7fa8c194b123314c20659d3f98c8e62617191dee0b44347712a1db48613fc675e"
    ["0.6.6"]="eeecdffd0ed9ff9d2b7b563f139bbf108baf1e7eea5e0a489f9418c45c2a9ccd22a332e4a67c139c9db1c35b2d8045f9457173c18e94978838cea883833c861b"
    ["0.6.5"]="66270ecf604ea242b4f28a58c68a455b5dd4ab39bbb7d903aec2a545adec766b20b8fc209e8ffdd49f30f6fa3e87421046ecc7e42855d2d5b4ca60d5f623bb92"
    ["0.6.4"]="af813728cd7040694d0a40dfeb6203c2fc2446970fdd924a2dc18d9aebfc0337b17623f41a7c5e5ed87d3da488486377a2de2597d3bd949a4717f4929db24c47"
    ["0.6.3"]="794ba1e0d32e47378adca16abd029712070806b5d252d9a2e282421766a20ed17114357dd6aafb6df7c73f7dca81adcf105fcb1c7ecaf4a1bbbdff3a3f66e41e"
    ["0.6.2"]="082add1100fb5a3025d7332bcb9939203f1425ee8bdf84a181fe35c97af82ff452e2a151580dda87046f0d4c46a0fb4b0a9dcbe06aaa82cbe0a488ddfa76ae59"
    ["0.6.1"]="1b21849ca1d74739f3a79506d04aee001e55a70e20427a80e01fb664d757a46187adcab95d152a50f634a5abaf567b2dfd670015f6761447e7f3e3f482fab06b"
    ["0.6.0"]="6ccdbf261aecf7c9ecb44cd19161eb049faa854db326fd44e8b88499c1f2da4377a76673ec4a70b6abdf3f5e2ec2b736adce70e18386a63b4b46359087d6575e"
    ["0.5.10"]="2b8677eb166386b5f3d21d8541316794cd6d43475284e23ab31c572f5cd388d057cfa6907d852b127b7ebedc7f3db8e4054d512482cec7ace4d271b499c84c6b"
    ["0.5.9"]="8d6fd064f5d04b8eb48324cec12bb9f8c22426d10e6e6f4399039efcf23d85abf103455364175c08abdf7fff820e1a519b6ab1685d701c03ce9dc5264f1649af"
    ["0.5.8"]="8ea5146590603d7c15000e78bef9341247b62e1988e89a8831ca7f1708d31621165770832d0b845c1f1d89116fbddfc27b5b34f87a7b29b7040f319ca7da3f16"
    ["0.5.7"]="68cad59fc7f78352bd06e74d61ede14426c9ce4c6e5007b1617e034f927a6b5b66a61ea5a0196fc6d7dbf81ef488bbe76519eda37658054c3c18da3ad1dd2912"
    ["0.5.6"]="25bb4e831371db4ce325625cad8a9b5256cf012a1fdce76481f9da8dba24987aabb8dd2f7d8acff5d16c6f5c3b318cd98450189d5e6469c1f2dc692e91f6e5e0"
    ["0.5.5"]="ac17f734f414da9f724e46ab9c82bff6cff1f7fdef8f2010c31e571b2a0ca236c5be800e1f7837eb4a15e9ca20a351fe7e929af918d9ab32a129f02643f11ae9"
    ["0.5.4"]="ec06f922dddb9a42d0376bcaa0035077e46d7caebde052d7bd6b06af2af856d56bd4b7e0088fab6fca38779fdd7c5e8608e9e955ac6352c44fc0433598793dab"
    ["0.5.3"]="3a62253bcf3b8ce1d3c7cdaf0885443720f9c9e1a4bad8a48f3982e43b0bb78aefdf7e31758b8dbcda6c95b6fd0fcd110b4e914dcaa0705e22164005e6b25eff"
    ["0.5.2"]="a9d6ae04419933deeb81a60d917c52f0469f9262ca89d213e0d3f9e927ff678f4dd78b23f2720c6db9ae9e230bc8ab3face50a6abb691874a3940daf67088c30"
    ["0.5.1"]="7ffde96df149d11bf3cb6f747052b31a75ea5b6568802190b16cedb4762fa8f35f16aff2f3afba01abd4981c0d66762a030baa60b92eadf4ae12aaef641db229"
    ["0.5.0"]="163999727f591bd68634a138705e76c9ee482ae3fe37c2fa40ad58c83ff3cd1441616434992b8b07991770ea2fc34bf23bc51dd9766f7d8fe25c749cbaeac64f"
    ["0.4.0"]="f3d4b0c3bcc2ad5cc7c765f6646f752dddf33be4a12ea784e4c7cd1bb4d5c2503206ad0fa0e624b8d628a58c6034e4aeebfffe0d7c289ac5c755e227647e104a"
    ["0.3.2"]="0fae623aaa60670519dfe9232cba01ac71763f7d3d7edb66db2e73f6244d3274b6049de22f0d2179ef8738c5d74b88ea8d93f35687d8b130ca883d10296758a4"
    # Versions 0.3.0 and 0.3.1 did not release correctly.
    ["0.2.0"]="a823f1f8da8dd606291255b347eb41eb351f3b97cf1fd770d04758f740a36b1207f32a1e6b9b942e701e87fbe2aa69fe7ea1685e6b80f8cbbe669a164d55ebe7"
    ["0.1.0"]="1eeb0e9c947702b689f9b6833323966c50d35c9f4de7d3f249ad0aede18a28e985f471aba8628a673e9e044280d590094a781e4ac6797aad946ee244c827d518"
)

# Verfies that the SHA-512 checksum of a file matches what was in the lookup table
verify_checksum() {
    local file=$1
    local expected_checksum=$2

    actual_checksum=$(sha512sum "${file}" | awk '{ print $1 }')

    echo "Verifying checksum for ${file}..."
    echo "  Actual: ${actual_checksum}"
    echo "  Expected: ${expected_checksum}"

    if [[ "${actual_checksum}" != "${expected_checksum}" ]]; then
        echo "ERROR: Checksum verification failed!"
        exit 1
    fi

    echo "Checksum verification passed!"
}

# Check if the melange tar file was in the CircleCI cache.
# Cache restoration is handled in install.yml
if [[ -f melange.tar.gz ]]; then
    tar zxvf melange.tar.gz "melange_${VERSION}_linux_amd64/melange" --strip 1
fi

# If there was no cache hit, go ahead and re-download the binary.
if [[ ! -f melange ]]; then
    wget "https://github.com/chainguard-dev/melange/releases/download/v${VERSION}/melange_${VERSION}_linux_amd64.tar.gz" -O melange.tar.gz
    tar zxvf melange.tar.gz "melange_${VERSION}_linux_amd64/melange" --strip 1
fi

# An melange binary should exist at this point, regardless of whether it was obtained
# through cache or re-downloaded. First verify its integrity.
if [[ "${VERIFY_CHECKSUMS}" != "false" ]]; then
    EXPECTED_CHECKSUM=${sha512sums[${VERSION}]}
    if [[ -n "${EXPECTED_CHECKSUM}" ]]; then
        # If the version is in the table, verify the checksum
        verify_checksum "melange" "${EXPECTED_CHECKSUM}"
    else
        # If the version is not in the table, this means that a new version of Melange
        # was released but this orb hasn't been updated yet to include its checksum in
        # the lookup table. Allow developers to configure if they want this to result in
        # a hard error, via "strict mode" (recommended), or to allow execution for versions
        # not directly specified in the above lookup table.
        if [[ "${VERIFY_CHECKSUMS}" == "known_versions" ]]; then
            echo "WARN: No checksum available for version ${VERSION}, but strict mode is not enabled."
            echo "WARN: Either upgrade this orb, submit a PR with the new checksum."
            echo "WARN: Skipping checksum verification..."
        else
            echo "ERROR: No checksum available for version ${VERSION} and strict mode is enabled."
            echo "ERROR: Either upgrade this orb, submit a PR with the new checksum, or set 'verify_checksums' to 'known_versions'."
            exit 1
        fi
    fi
else
    echo "WARN: Checksum validation is disabled. This is not recommended. Skipping..."
fi

# After verifying integrity, install it by moving it to an appropriate bin
# directory and marking it as executable. If your pipeline throws an error
# here, you may want to choose an INSTALL_PATH that doesn't require sudo access,
# so this orb can avoid any root actions.
mv melange "${INSTALL_PATH}/melange"
chmod +x "${INSTALL_PATH}/melange"