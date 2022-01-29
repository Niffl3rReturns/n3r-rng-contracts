// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.6;

import "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/dev/VRFConsumerBaseV2.sol";
import "@pooltogether/owner-manager-contracts/contracts/Ownable.sol";

import "./interfaces/RNGChainlinkInterface.sol";

contract RNGChainlink is RNGChainlinkInterface, VRFConsumerBaseV2, Ownable {
  /* ============ Global Variables ============ */

  /// @dev Reference to the VRFCoordinatorV2 deployed contract
  VRFCoordinatorV2Interface private _vrfCoordinator;

  /// @dev Reference to the LINK token contract.
  LinkTokenInterface private immutable _linkToken;

  /// @dev The keyhash used by the Chainlink VRF
  bytes32 public keyHash;

  /// @dev A counter for the number of requests made used for request ids
  uint256 public requestCounter;

  /// @dev A list of random numbers from past requests mapped by request id
  mapping(uint256 => uint256) internal randomNumbers;

  /// @dev A list of blocks to be locked at based on past requests mapped by request id
  mapping(uint256 => uint256) internal requestLockBlock;

  /// @dev A mapping from Chainlink request ids to internal request ids
  mapping(uint256 => uint256) internal chainlinkRequestIds;

  /// @notice Chainlink VRF subscription request configuration
  RequestConfig public sRequestConfig;

  /// @notice Chainlink VRF subscription random words
  uint256[] public sRandomWords;

  /// @notice Chainlink VRF subscription request id
  uint256 public sRequestId;

  /* ============ Structs ============ */

  /**
   * @notice Chainlink VRF request configuration to request random numbers
   * TODO: Complete documentation
   * @param subId Subscription id
   * @param callbackGasLimit
   * @param requestConfirmations
   * @param numWords Number of random values to receive
   * @param keyHash Hash of the public key used to verify the VRF proof
   */
  struct RequestConfig {
    uint64 subId;
    uint32 callbackGasLimit;
    uint16 requestConfirmations;
    uint32 numWords;
    bytes32 keyHash;
  }

  /* ============ Events ============ */

  /**
   * @notice Emmited when the Chainlink VRF keyHash is set
   * @param keyHash Chainlink VRF keyHash
   */
  event KeyHashSet(bytes32 keyHash);

  /**
   * @notice Emmited when the Chainlink VRF Coordinator address is set
   * @param vrfCoordinator Address of the VRF Coordinator
   */
  event VrfCoordinatorSet(VRFCoordinatorV2Interface indexed vrfCoordinator);

  /**
   * @notice Emitted when LINK tokens have been withdrawn from the contract
   * @param amount The amount of LINK tokens that was withdrawn
   * @param recipient The address that received the LINK tokens
   */
  event LinkWithdrawn(uint256 amount, address indexed recipient);

  /**
   * @notice Emitted when the Chainlink VRF subscription has been topped up
   * @param amount The amount of LINK that was added to the subscription
   * @param sender The address that sent the LINK tokens
   */
  event SubscriptionToppedUp(uint256 amount, address indexed sender);

  /* ============ Constructor ============ */

  /// @dev Public constructor
  constructor(
    address _owner,
    address vrfCoordinator_,
    address linkToken_,
    uint32 _callbackGasLimit,
    uint16 _requestConfirmations,
    uint32 _numWords,
    bytes32 _keyHash
  ) Ownable(_owner) VRFConsumerBaseV2(vrfCoordinator_) {
    _vrfCoordinator = VRFCoordinatorV2Interface(vrfCoordinator_);
    _linkToken = LinkTokenInterface(linkToken_);
    keyHash = _keyHash;

    sRequestConfig = RequestConfig({
      subId: 0, // Unset initially, will be set by subscribe()
      callbackGasLimit: _callbackGasLimit,
      requestConfirmations: _requestConfirmations,
      numWords: _numWords,
      keyHash: _keyHash
    });

    subscribe();

    emit KeyHashSet(_keyHash);
    emit VrfCoordinatorSet(_vrfCoordinator);
  }

  /* ============ External Functions ============ */

  /// @inheritdoc RNGChainlinkInterface
  function subscribe() public override onlyOwner {
    address[] memory consumers = new address[](1);
    consumers[0] = address(this);

    sRequestConfig.subId = _vrfCoordinator.createSubscription();
    _vrfCoordinator.addConsumer(sRequestConfig.subId, consumers[0]);
  }

  /// @inheritdoc RNGChainlinkInterface
  function unsubscribe(address _to) external override onlyOwner {
    _vrfCoordinator.cancelSubscription(sRequestConfig.subId, _to);
    sRequestConfig.subId = 0;
  }

  /// @inheritdoc RNGInterface
  function requestRandomNumber() external override returns (uint256 requestId, uint256 lockBlock) {
    lockBlock = block.number;

    _requestRandomWords(sRequestConfig);

    requestId = sRequestId;
    requestLockBlock[requestId] = lockBlock;

    emit RandomNumberRequested(requestId, msg.sender);
  }

  /// @inheritdoc RNGChainlinkInterface
  function requestRandomWords() external override onlyOwner {
    RequestConfig memory _requestConfig = sRequestConfig;
    _requestRandomWords(_requestConfig);
  }

  /// @inheritdoc RNGChainlinkInterface
  function fundAndRequestRandomWords(uint256 _amount) external override onlyOwner {
    RequestConfig memory _requestConfig = sRequestConfig;

    _linkToken.transferAndCall(address(_vrfCoordinator), _amount, abi.encode(_requestConfig.subId));
    _requestRandomWords(_requestConfig);
  }

  /// @inheritdoc RNGChainlinkInterface
  function topUpSubscription(uint256 _amount) external override {
    _requireAmountGreaterThanZero(_amount);

    uint256 _linkBalance = _linkToken.balanceOf(address(this));

    if (_linkToken.balanceOf(address(this)) == 0 || _linkBalance < _amount) {
      uint256 _transferAmount = _linkBalance < _amount ? (_amount - _linkBalance) : _amount;

      _linkToken.transferFrom(msg.sender, address(this), _transferAmount);
    }

    _linkToken.transferAndCall(address(_vrfCoordinator), _amount, abi.encode(sRequestConfig.subId));

    emit SubscriptionToppedUp(_amount, msg.sender);
  }

  /// @inheritdoc RNGChainlinkInterface
  function withdrawLink(uint256 _amount, address _to) external override onlyOwner {
    require(_to != address(0), "RNGChainLink/to-not-zero-address");
    _requireAmountGreaterThanZero(_amount);

    _linkToken.transfer(_to, _amount);

    emit LinkWithdrawn(_amount, _to);
  }

  /// @inheritdoc RNGInterface
  function isRequestComplete(uint256 requestId) external view override returns (bool isCompleted) {
    return randomNumbers[requestId] != 0;
  }

  /// @inheritdoc RNGInterface
  function randomNumber(uint256 requestId) external view override returns (uint256 randomNum) {
    return randomNumbers[requestId];
  }

  /// @inheritdoc RNGInterface
  function getLastRequestId() external view override returns (uint256 requestId) {
    return requestCounter;
  }

  /// @inheritdoc RNGChainlinkInterface
  function getLink() external view override returns (address) {
    return address(_linkToken);
  }

  /// @inheritdoc RNGChainlinkInterface
  function getSubscriptionId() public view override returns (uint64) {
    return sRequestConfig.subId;
  }

  /// @inheritdoc RNGChainlinkInterface
  function setKeyhash(bytes32 _keyhash) external override onlyOwner {
    sRequestConfig.keyHash = _keyhash;

    emit KeyHashSet(_keyhash);
  }

  /* ============ Internal Functions ============ */

  /**
   * @notice Callback function called by VRF Coordinator
   * @dev The VRF Coordinator will only call it once it has verified the proof associated with the randomness.
   */
  function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
    require(_requestId == sRequestId, "RNGChainLink/requestId-incorrect");
    sRandomWords = _randomWords;

    uint256 _internalRequestId = chainlinkRequestIds[_requestId];
    uint256 _randomNumber = _randomWords[0];

    randomNumbers[_internalRequestId] = _randomNumber;

    emit RandomNumberCompleted(_internalRequestId, _randomNumber);
  }

  /**
   * @notice Requests new random words from the Chainlink VRF.
   * @dev The result of the request is returned in the function `fulfillRandomWords`.
   * @dev Will revert if subscription is not set and/or funded.
   */
  function _requestRandomWords(RequestConfig memory _requestConfig) internal {
    uint256 _vrfRequestId = _vrfCoordinator.requestRandomWords(
      _requestConfig.keyHash,
      _requestConfig.subId,
      _requestConfig.requestConfirmations,
      _requestConfig.callbackGasLimit,
      _requestConfig.numWords
    );

    sRequestId = _vrfRequestId;
    chainlinkRequestIds[_vrfRequestId] = requestCounter;

    emit RandomNumberRequested(requestCounter++, msg.sender);
  }

  /**
   * @notice Require amount greater than 0.
   * @dev Reverts if amount is less than or equal to 0.
   * @param _amount The amount to be checked
   */
  function _requireAmountGreaterThanZero(uint256 _amount) internal pure {
    require(_amount > 0, "RNGChainLink/amount-gt-zero");
  }
}
