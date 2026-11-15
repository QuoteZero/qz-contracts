// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title QZAddresses
/// @notice Third-party addresses the spec names (docs/SPEC.md §0, §3.1, §3.2, §5.2). All checked for code on the
///         Robinhood fork in test/C0Smoke.t.sol (home chain only; Ink and Base are listed for C9 `CheckLzConfig`).
///         The ten stock-token addresses come from the Quotrons bundle (§3.1) and are NOT yet matched against the
///         official directory docs.robinhood.com/chain/contracts (spec: [belum terverifikasi], unit C5 must match
///         them before `sealRoutes()`).
library QZAddresses {
    // ── Robinhood Chain (4663), §0 ──
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    // ── §3.2 conversion route: WETH -> USDG (v3, fee 0.01%) -> stock (v4) ──
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant V3_SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    // ── §3.1 stock-token registry (blocklist and pause) and Stock implementation (beacon) ──
    address internal constant STOCK_REGISTRY = 0xe10b6f6B275de231345c20D14Ab812db62151b00;
    address internal constant STOCK_IMPLEMENTATION = 0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2;
    /// @dev S0 snapshot target (Quotrons V2 core on Robinhood).
    address internal constant QUOTRONS_V2_CORE = 0x5a86828Efd322bfb16d93cFeD16EE9BC14940D7F;

    // ── §3.1 the ten stock tokens, track index 0..9 in this order ──
    address internal constant STOCK_NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant STOCK_AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant STOCK_TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address internal constant STOCK_GME = 0x1b0E319c6A659F002271B69dB8A7df2F911c153E;
    address internal constant STOCK_SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address internal constant STOCK_PLTR = 0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A;
    address internal constant STOCK_NFLX = 0xE0444EF8BF4eD74f74FD73686e2ddF4C1c5591E8;
    address internal constant STOCK_RDDT = 0x05b37Fb53A299a1b874A619e1c4C404D52C36F4C;
    address internal constant STOCK_MSTR = 0xec262a75e413fAfD0dF80480274532C79D42da09;
    address internal constant STOCK_SPCX = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa;

    error BadTrack(uint8 track);

    /// @notice Stock token for `track` (0..9).
    function stockOf(uint8 track) internal pure returns (address) {
        if (track == 0) return STOCK_NVDA;
        if (track == 1) return STOCK_AAPL;
        if (track == 2) return STOCK_TSLA;
        if (track == 3) return STOCK_GME;
        if (track == 4) return STOCK_SPY;
        if (track == 5) return STOCK_PLTR;
        if (track == 6) return STOCK_NFLX;
        if (track == 7) return STOCK_RDDT;
        if (track == 8) return STOCK_MSTR;
        if (track == 9) return STOCK_SPCX;
        revert BadTrack(track);
    }

    // ── §5.2 LayerZero V2 deployments ──
    address internal constant LZ_ENDPOINT_ROBINHOOD = 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B;
    address internal constant LZ_ENDPOINT_INK = 0xca29f3A6f966Cb2fc0dE625F8f325c0C46dbE958;
    address internal constant LZ_ENDPOINT_BASE = 0x1a44076050125825900e736c501f859c50fE728c;
    address internal constant LZ_SEND_ULN_ROBINHOOD = 0xC39161c743D0307EB9BCc9FEF03eeb9Dc4802de7;
    address internal constant LZ_SEND_ULN_INK = 0x76111DE813F83AAAdBD62773Bf41247634e2319a;
    address internal constant LZ_SEND_ULN_BASE = 0xB5320B0B3a13cC860893E2Bd79FCd7e13484Dda2;
    address internal constant LZ_RECEIVE_ULN_ROBINHOOD = 0xe1844c5D63a9543023008D332Bd3d2e6f1FE1043;
    address internal constant LZ_RECEIVE_ULN_INK = 0x473132bb594caEF281c68718F4541f73FE14Dc89;
    address internal constant LZ_RECEIVE_ULN_BASE = 0xc70AB6f32772f59fBfc23889Caf4Ba3376C84bAf;
    address internal constant LZ_EXECUTOR_ROBINHOOD = 0x4208D6E27538189bB48E603D6123A94b8Abe0A0b;
    address internal constant LZ_EXECUTOR_INK = 0xFEbCF17b11376C724AB5a5229803C6e838b6eAe5;
    address internal constant LZ_EXECUTOR_BASE = 0x2CCA08ae69E0C44b18a57Ab2A87644234dAebaE4;
    address internal constant DVN_LZ_LABS_ROBINHOOD = 0xd01ae6905d48315f7bE10C7330aeCF8360Ef5b12;
    address internal constant DVN_LZ_LABS_INK = 0x174F2bA26f8ADeAfA82663bcf908288d5DbCa649;
    address internal constant DVN_LZ_LABS_BASE = 0x9e059a54699a285714207b43B055483E78FAac25;
    address internal constant DVN_DEUTSCHE_TELEKOM_ROBINHOOD = 0x70F5a195f6DA203e839Bb5F15e53d3a0Fc796925;
    address internal constant DVN_DEUTSCHE_TELEKOM_INK = 0xbbaDa47d1dd5F5B04414178E841a5a508C57bfaf;
    address internal constant DVN_DEUTSCHE_TELEKOM_BASE = 0xc2A0C36f5939A14966705c7Cec813163FaEEa1F0;
    address internal constant DVN_HORIZEN_ROBINHOOD = 0x1258A278519c7f4bd997a9c3BFd4Aa802a028D89;
    address internal constant DVN_HORIZEN_INK = 0x395B14700812cccC38b8e64F0a06ce2045FE9bA3;
    address internal constant DVN_HORIZEN_BASE = 0xa7b5189bcA84Cd304D8553977c7C614329750d99;
    address internal constant DVN_P2P_ROBINHOOD = 0x8ed0A851964604BB1b6b1a703F4c8234EE684d76;
    address internal constant DVN_P2P_INK = 0x68b6Fb5e728dB92A09BA810595915aE3d7399e40;
    address internal constant DVN_P2P_BASE = 0x5b6735c66d97479cCD18294fc96B3084EcB2fa3f;
}
