// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;


import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

//import { MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
//import { MessagingFee } from "@layerzerolabs/layerzero-v2/evm/oapp/contracts/oapp/OApp.sol";

import { OFTAdapter } from "@layerzerolabs/layerzero-v2/evm/oapp/contracts/oft/OFTAdapter.sol";
import { SendParam } from "@layerzerolabs/layerzero-v2/evm/oapp/contracts/oft/interfaces/IOFT.sol";
import { MessagingFee } from "@layerzerolabs/layerzero-v2/evm/oapp/contracts/oapp/OApp.sol";

import { ILayerZeroEndpointV2 } from "@layerzerolabs/layerzero-v2/evm/oapp/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { ILayerZeroReceiver } from "@layerzerolabs/layerzero-v2/evm/oapp/contracts/interfaces/ILayerZeroReceiver.sol";
import { PacketV1Codec } from "@layerzerolabs/layerzero-v2/evm/oapp/contracts/precrime/libs/PacketV1Codec.sol";

import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";


/// @notice OFTAdapter uses a deployed ERC-20 token and SafeERC20 to interact with the OFTCore contract.
contract BfpOFTAdapter is OFTAdapter {

    // ===== Limits =====
    uint256 public dailyLimit;
    uint256 public txLimit;

    uint256 public dailyUsed;
    uint256 public lastReset;
    address public token;
    
    constructor(
        address _token,
        address _lzEndpoint,
        address _owner
    ) OFTAdapter(_token, _lzEndpoint, _owner) Ownable(_owner) {

        token = _token;

    }

     function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }


    // ===== CORE OVERRIDE =====

    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    )
        public
        payable
        override
    {
        dailyUsed += _sendParam.amountLD;
        super.send(_sendParam, _fee, _refundAddress);
    }
}