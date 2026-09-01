// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

/// @title MockKycNFT
/// @notice WisdomTree KYC NFT의 목업. 소울바운드이고 safeMint만 제공합니다.
///
/// @dev 실물(Sepolia 0xf10fdd8a…)의 확인된 동작을 재현합니다.
///      - safeMint(address to) 하나. tokenId는 내부에서 채번하며 인자에 없습니다.
///      - transferFrom / safeTransferFrom은 조건 없이 항상 revert합니다.
///      - 수신자가 컨트랙트면 onERC721Received를 호출하고 매직값이 아니면 revert합니다.
///
///      마지막 항목이 M2의 존재 이유입니다. EVK 원본 볼트에는 onERC721Received가 없어
///      safeMint가 revert하고, 볼트가 화이트리스트 자격을 얻지 못합니다.
contract MockKycNFT {
    error NotTransferable();
    error MintToZeroAddress();
    error NonReceiverImplementer();
    error NotMinter();
    error TokenDoesNotExist();

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    string public constant name = "Mock KYC Soulbound";
    string public constant symbol = "MKYC";

    address public immutable minter;
    uint256 public totalSupply;

    mapping(uint256 tokenId => address owner) public ownerOf;
    mapping(address owner => uint256 count) public balanceOf;

    constructor(address minter_) {
        minter = minter_;
    }

    /// @notice 실물과 같은 시그니처. tokenId를 받지 않습니다.
    function safeMint(address to) external {
        if (msg.sender != minter) revert NotMinter();
        _safeMint(to);
    }

    function batchSafeMint(address[] calldata toList) external {
        if (msg.sender != minter) revert NotMinter();
        for (uint256 i = 0; i < toList.length; ++i) {
            _safeMint(toList[i]);
        }
    }

    function _safeMint(address to) internal {
        if (to == address(0)) revert MintToZeroAddress();

        uint256 tokenId = ++totalSupply;
        ownerOf[tokenId] = to;
        unchecked {
            balanceOf[to] += 1;
        }
        emit Transfer(address(0), to, tokenId);

        // 수신자가 컨트랙트면 콜백을 요구합니다. EVK 원본 볼트는 여기서 걸립니다.
        if (to.code.length > 0) {
            try IERC721Receiver(to).onERC721Received(msg.sender, address(0), tokenId, "") returns (bytes4 ret) {
                if (ret != IERC721Receiver.onERC721Received.selector) revert NonReceiverImplementer();
            } catch {
                revert NonReceiverImplementer();
            }
        }
    }

    // --- 소울바운드: 아래는 전부 revert ---

    function transferFrom(address, address, uint256) external pure {
        revert NotTransferable();
    }

    function safeTransferFrom(address, address, uint256) external pure {
        revert NotTransferable();
    }

    function safeTransferFrom(address, address, uint256, bytes calldata) external pure {
        revert NotTransferable();
    }

    function approve(address, uint256) external pure {
        revert NotTransferable();
    }

    function setApprovalForAll(address, bool) external pure {
        revert NotTransferable();
    }
}
