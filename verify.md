in root with

libraries = [
"lib/spark-alm-controller/src/libraries/LayerZeroLib.sol:LayerZeroLib:0xa44a27901ee51d657f59c75a61521e332cdc2e2e"
]

$ forge verify-bytecode 0x83A914C361bB729EB6BEBC8C7bA993667A0E6Df8 ALMProxy --rpc-url https://rpc.xlayer.tech --verifier-url "http://localhost:8443" --chain 196
$ forge verify-bytecode 0x7F7E2286983994c4403Cf2B86758cE0e7bA666a8 RateLimits --rpc-url https://rpc.xlayer.tech --verifier-url "http://localhost:8443" --chain 196
$ forge verify-bytecode 0xf9187C99Ee842beABE8e2e346d958315BFc9331f ForeignController --rpc-url https://rpc.xlayer.tech --verifier-url "http://localhost:8443" --chain 196
$ forge verify-bytecode 0xc358c90D32375721Cb3924320Fdc2F8B694347Ca ERC1967Proxy --rpc-url https://rpc.xlayer.tech --verifier-url "http://localhost:8443" --chain 196
$ forge verify-bytecode 0xdCe929A335C75a1676EF5957A4D7a3b928C48820 SparkVault --rpc-url https://rpc.xlayer.tech --verifier-url "http://localhost:8443" --chain 196

in lib/spark-alm-controller

optimizer_runs = 200

$ forge verify-bytecode 0x9449ed367C60ea757544fd990B57e1C2D0Ec3A94 ALMProxyFreezable --rpc-url https://rpc.xlayer.tech --verifier-url "http://localhost:8443" --chain 196

in lib/spark-gov-relay

$ forge verify-bytecode 0xCF5af6F53ceC74B791cb4182aC778ca9CD323510 Executor --rpc-url https://rpc.xlayer.tech --verifier-url "http://localhost:8443" --chain 196

in lib/xchain-helpers

solc_version = '0.8.25'
optimizer = true
optimizer_runs = 200
evm_version = 'cancun'

$ forge verify-bytecode 0x4bd50B9c00Ae19e8B59723F27645C7A5cCe7a4A0 OptimismReceiver --rpc-url https://rpc.xlayer.tech --verifier-url "http://localhost:8443" --chain 196
