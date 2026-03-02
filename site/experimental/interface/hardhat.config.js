require("@nomicfoundation/hardhat-verify");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
    solidity: "0.8.20",
    networks: {
        gnosis: {
            url: "https://rpc.gnosischain.com",
            chainId: 100,
        },
    },
    etherscan: {
        apiKey: {
            gnosis: process.env.GNOSISSCAN_API_KEY || "",
        },
        customChains: [
            {
                network: "gnosis",
                chainId: 100,
                urls: {
                    apiURL: "https://api.gnosisscan.io/api",
                    browserURL: "https://gnosisscan.io",
                },
            },
        ],
    },
};
