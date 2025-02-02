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
    ["0.19.3"]="b5fa0630aeb1174be53220a98489b890d788e520d14b05245dc9c78e3f2daf322bd93493c80f356e09b52cfdf3cdaa7d3d82ef4c8f63bf7a71f4db03a7d7f796"
    ["0.19.2"]="8dc6e1a17a991aac3967c5f95482ad8c305d02ed2b22ac6b3f9eb3a0589551991206c6889dc946324cd839b365b48ce909b4f28be0c3617b69f0543f14b40773"
    ["0.19.1"]="3e78b941915be855e8afc6dfb1b58692c042cfabb856166aac2dad3fb7b7d7c1fbb10ed87fdaca6a44e7bcb125a9bd75002837ade4792ad618a7fff5902326de"
    ["0.19.0"]="4cd37271b829284fff4383399eeb4bc20cfdb26692f40d7971c376a9e636153302134426d0a861a888365765ee7009c40d6391e62e33f96710028d88c2f71840"
    ["0.18.3"]="fa46be2c957f9e846cca9cff0ba8fb89ab202031c3e9f58de756c95b6529533982c4a459ee4ed4da927e007f56af9744985237051459fe9a9d4afd88ce5bc86f"
    ["0.18.2"]="201ae924f5dfb69883286a53755677589c7401bba79e597db0f9094206cd744accebfe37f86a2f9cf0abc4b9ed12859773a8d2cc054dbc08c9adcb0db4f03fd9"
    ["0.18.1"]="c2f405b3f9f3b3124e0569677459b84f494c584ad996be19dfd5a05ab3171775d2aa39276d67ac1b197e57da078fe358825d4534018f18f37556dbd391303195"
    ["0.18.0"]="aa0407a64406bbc3a5dcabdd896a05fe0834c0602a3d7cacde10ea163b63dbe0eb9207a18322d2e5fc77f90276bd345ef2d5b835103d60b653e7ab04850e3336"
    ["0.17.7"]="8a720896e9e2ed7ccec609333aa6cea6c1ded90d64088b3ae5148cc5a857fadd4137857ab1b7ca5b5293770eae47a56213d343224b768f85acf994130b73fce8"
    ["0.17.6"]="1e8448e8881f72e2c2a12819ea6c8efad5c59bde175859a90c05af8c22dd9e3300da26160df6015943211ca465107eada34cd2a3f6d5f6092ec24ede1896a9e8"
    ["0.17.5"]="b7f38cbb86f3307e98f4153538648c4d11adef22177cb5d82cdbfeedc815efb030757fbf219ae725893aec75055742314f41592e7cfce05fd71326087b09269a"
    ["0.17.4"]="ab3bd7901448b070a1e637be279a7b6fc342829b982b39ddd3cc2939bb9614c568a476e513bc45ba796c62ef1e8712229a609e506b3b44d660ca47e6f7dcf404"
    ["0.17.3"]="ca04e02701d256cedd500cf237dcb2fa4bbc0e81ba2478110f9e989ffa1a0ca0e8531fdb358c3023d3c25add0ad1b0f6cf00aa8a4a0552ba0c2a9f5231976b9e"
    ["0.17.2"]="29f179afebca0bcb7aa130d7e4b4dc18523ed71d385bd906e389dc36ee7bf75eec9f68639d73d098da3b5072842231947b89b4b32451df48fe5df02bc534a9eb"
    ["0.17.1"]="a9b93afef1fb38dd19ddedf9c491f33068e9094020e1c1b221ca66b272f1f3bc12b6d6b0183a96b8f0bc9dfd5ec4055e6c0442c9d4ff42b370cebe3d09d0283d"
    ["0.17.0"]="403ac168dc7c41dfdaa7751893c76ca5fd84ddc4fbd86691a3c8d6edc92b3237c2fe9c3db99f5377a9f0d03b1b7debd4656d312bf9ea6221b2e4e9987da689a2"
    # Version 0.16.0 did not release correctly.
    ["0.15.14"]="2137b42e0e61e1eaff8d1bff42d83fc56cc48fd04d637b74291c93d413b8340575d23a70ad9b23e583e7b130c67a906f5949726de47891bcdd6bdd9d4da15e1c"
    ["0.15.13"]="a333f101bb4ebf4a3196213d31cb6f5dbc1eb67b78f846cf3b7097c4460f5b89b9ef9d0141f4082f93a93fd5e6d9b54cb2e3b4dcaf90d90299983c808a1a0fbc"
    ["0.15.12"]="00a1b60ffcb80135069aa37c76f70f461138f769d1a520b3d21e85ce98134771ac1b1e2f01ee672b3b3586ed62293156edf79999cc083877e0a87beed219e46f"
    ["0.15.11"]="8db23b9c30b9f5c027b0e25a918e0be0893364d5ce5f6f9a98914e16a31dbb58e61d2ebb16ce5ee384f171e5a49f64d90847dad5141a7e1d892d0c380ac21f36"
    # Versions 0.15.0 through 0.15.10 did not release correctly.
    ["0.14.10"]="d4f9e7b9514981a5298cdb80d8df6c7c53308878d2174e6ba16e13e3beef4cb8f41d9d4a68f62f01c2d703f8c4ddc877b9dc574e2a00401b75e5f9a1c1a283fe"
    # Versions 0.14.8 and 0.14.9 did not release correctly.
    ["0.14.7"]="1239aa51f1e3ababe291dd8ac3a2981e7e93a60af17e19c01fd603837557a7264a24b6b84ccf94ce6958f5ce966d1f8a8f537c04f6a3deec6f6205bccab653a9"
    # Versions 0.14.5 and 0.14.6 did not release correctly.
    ["0.14.4"]="7d40c44cd86e0d31b47686d7bd10e3aa5560e1eea0f4c2bd81453999dcfda2a8c304a3937ba2cb727a044262a8cb5e5b120615a945bacc99469c64e3b88f7f1e"
    # Versions 0.14.2 and 0.14.3 did not release correctly.
    ["0.14.1"]="cee0262a7f469e4ba68ed2985669097f992b38a32c59da1541ed0f1e97f8821f5f089279d5b815b0b8e76b12b3d88789bb55512ccc6118272c7fb3d46ce4b189"
    ["0.14.0"]="c2331cd3f3ffcadafbcca96795ebe9764c906d4547c4aa59326ac5a0b7aa44be3f334af97e4cdcd778f647fcfdf1f23d6e955ee1cba47e8b9d73def04aeb680a"
    ["0.13.7"]="1542e182b1d89b3c7089864c4537bb134416327653ec9c413362c2ca33595ac6f0fbd97fba265ab52e3d2ec237b3692846a044197461f84a45f3dbcacc30e0aa"
    ["0.13.6"]="179c5da4649e61d034932c72558fe56247cb4a552c2baf8e3c699558d00e4762b5ffc0880fcc191bf6c92d8fab4a6ee7887f09d4db809db3f4892cc5574d805a"
    ["0.13.5"]="0fb784e63dc134658e6d43ac6864bd871c8c94e2d77580c68e2e5c84eb6d03cc7e30341ee9b7c9aa5ef708ab2a1f4b6aa01d8ec08fe2ecc4e74108bcd34f154e"
    ["0.13.4"]="374574ce34a2cf333a304809ee4cbdb6a18ee6147d572ef56ca7349aea94c1c892df4462f76995239cfc20ed877b1a8e59e0a0a4337bcc86db940b2a9253866b"
    ["0.13.3"]="f8c94573cbf1fbc242dbe0024b6eb8b9d0ef72ca159d58c2b49a03191b59325a55a410981754a67f22a0afd63bbc1bc1111e173f6c49c6550a37c9c9e8190c9d"
    ["0.13.2"]="b1199a7241d7f0ebbbe547b93d05d808b9a604a15ccb0f6bdbe25f6aaa33edad950aab6612bb2c720f84c7729c53688df70653c2ebdebf14a38a245a9dfb9468"
    ["0.13.1"]="5840754c22e37492e031c46eef3b229e77a5e086f9b408e9287197f5de2fdd8d83ec72d6a55598db2c804a96b34407b7ada264849d74e79cfb37f4edbd864cae"
    ["0.13.0"]="689a549ffa1c16ca6b9eb3bc5bab758d4e1e943d1b8b9a151f94b18f365f921e16a58407e3fae2dde940d0a7a1e0f627e2cf7cfa4fc343cd41a054d6eaaf3eeb"
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