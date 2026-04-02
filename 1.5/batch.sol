// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Interface simplifiée pour appeler ton CORE
interface IBrokexCore {
    function executeOrder(uint256 tradeId, bytes calldata oracleProof) external;
    function liquidatePosition(uint256 tradeId, bytes calldata oracleProof) external;
    function executeStopOrTakeProfit(uint256 tradeId, bytes calldata oracleProof) external;
}

contract BrokexBatcher {
    IBrokexCore public immutable core;
    address public owner;

    // Codes des actions :
    // 0 = Execute Order (Entrée de position Limit/Stop)
    // 1 = Liquidate Position (Liquidation)
    // 2 = Execute Stop Or Take Profit (Sortie de position SL/TP)

    constructor(address _coreAddress) {
        require(_coreAddress != address(0), "Core address cannot be zero");
        core = IBrokexCore(_coreAddress);
        owner = msg.sender;
    }

    // Sécurité basique pour que seul ton bot puisse utiliser ce contrat
    modifier onlyOwner() {
        require(msg.sender == owner, "Not authorized");
        _;
    }

    /**
     * @notice Exécute un batch d'opérations sur BrokexCore avec une seule preuve.
     * @param actions Tableau des codes d'action (0, 1 ou 2)
     * @param tradeIds Tableau des IDs de trades correspondants
     * @param oracleProof La preuve Supra Oracle (envoyée une seule fois !)
     */
    function executeBatch(
        uint8[] calldata actions,
        uint256[] calldata tradeIds,
        bytes calldata oracleProof
    ) external onlyOwner {
        require(actions.length == tradeIds.length, "Arrays length mismatch");

        for (uint256 i = 0; i < actions.length; i++) {
            uint8 action = actions[i];
            uint256 tradeId = tradeIds[i];

            // Utilisation de try/catch pour éviter qu'un échec ne fasse revert tout le lot
            if (action == 0) {
                try core.executeOrder(tradeId, oracleProof) {} catch {}
            } 
            else if (action == 1) {
                try core.liquidatePosition(tradeId, oracleProof) {} catch {}
            } 
            else if (action == 2) {
                try core.executeStopOrTakeProfit(tradeId, oracleProof) {} catch {}
            }
        }
    }

    // Permet de changer le owner (utile si tu changes de wallet bot)
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "New owner is zero address");
        owner = newOwner;
    }
}
