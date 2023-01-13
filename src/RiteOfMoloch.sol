// SPDX-License-Identifier: MIT
// @author st4rgard3n, bitbeckers, MrDeadce11, huntrr / Raid Guild
pragma solidity ^0.8.4;

import "lib/openzeppelin-contracts-upgradeable/contracts/utils/CountersUpgradeable.sol";
import "lib/openzeppelin-contracts-upgradeable/contracts/token/ERC721/ERC721Upgradeable.sol";
import "./InitializationData.sol";
import "src/hats/HatsAccessControl.sol";
import {IHats} from "src/hats/IHats.sol";

interface MolochDAO {
    struct Member {
        address delegateKey; // the key responsible for submitting proposals and voting - defaults to member address unless updated
        uint256 shares; // the # of voting shares assigned to this member
        uint256 loot; // the loot amount available to this member (combined with shares on ragequit)
        bool exists; // always true once a member has been created
        uint256 highestIndexYesVote; // highest proposal index # on which the member voted YES
        uint256 jailed; // set to proposalIndex of a passing guild kick proposal for this member, prevents voting on and sponsoring proposals
    }

    function members(address memberAddress)
        external
        view
        returns (Member calldata member);
}

interface Token {
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    function transfer(address to, uint256 amount) external returns (bool);
}

contract RiteOfMoloch is
    InitializationData,
    ERC721Upgradeable,
    HatsAccessControl
{
    using CountersUpgradeable for CountersUpgradeable.Counter;

    mapping(bytes32 => RoleData) public _roles;

    // role constants
    bytes32 public constant SUPER_ADMIN = keccak256("SUPER_ADMIN");
    bytes32 public constant ADMIN = keccak256("ADMIN");

    /*************************
     MAPPING STRUCTS EVENTS
     *************************/

    // logs new initiation data
    event Initiation(
        address newInitiate,
        address benefactor,
        uint256 tokenId,
        uint256 stake,
        uint256 deadline
    );

    // logs data when failed initiates get slashed
    event Sacrifice(address sacrifice, uint256 slashedAmount, address slasher);

    // logs data when a user successfully claims back their stake
    event Claim(address newMember, uint256 claimAmount);

    // log the new staking requirement
    event ChangedStake(uint256 newStake);

    // log the new minimum shares for DAO membership
    event ChangedShares(uint256 newShare);

    // log the new duration before an initiate can be slashed
    event ChangedTime(uint256 newTime);

    // log feedback data on chain for aggregation and graph
    event Feedback(address user, address treasury, string feedback);

    // initiation participant token balances
    mapping(address => uint256) internal _staked;

    // the time a participant joined the initiation
    mapping(address => uint256) public deadlines;

    // the number of user's a member has sacrificed
    mapping(address => uint256) public totalSlash;

    /*************************
     STATE VARIABLES
     *************************/

    CountersUpgradeable.Counter internal _tokenIdCounter;

    MolochDAO public dao;

    Token private _token;

    // cohort's base URI for accessing token metadata
    string internal __baseURI;

    // cohort name
    string public cohortName;

    // cohort size limit
    uint256 public cohortSize;

    // cohort join time limit
    uint256 public joinEndTime;

    // minimum amount of dao shares required to be considered a member
    uint256 public minimumShare;

    // minimum amount of staked tokens required to join the initiation
    uint256 public minimumStake;

    // maximum length of time for initiates to succeed at joining
    uint256 public maximumTime;

    // DAO treasury address
    address public treasury;

    // Hats protocol:
    IHats public HATS;

    // Hats
    uint256 public topHat;
    uint256 public superAdminHat;
    uint256 public adminHat;

    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Deploys a new clone proxy instance for cohort staking
     * @param initData the complete initialization data
     * @param caller_ the deployer of the new cohort clone
     */
    function initialize(
        InitData calldata initData,
        address hatsProtocol,
        address caller_
    ) external initializer {
        // increment the counter so our first sbt has token id of one
        _tokenIdCounter.increment();

        // set cohort name
        cohortName = initData.cohortName;

        // set size limit on cohort
        cohortSize = initData.cohortSize;

        // set join time limit
        joinEndTime = block.timestamp + initData.joinDuration;

        // initialize the SBT
        __ERC721_init(initData.sbtName, initData.sbtSymbol);

        // set the interface for accessing the DAO's public members mapping
        dao = MolochDAO(initData.membershipCriteria);

        // store the treasury daoAddress
        treasury = initData.treasury;

        // set the interface for accessing the required staking token
        _token = Token(initData.stakingAsset);

        // set the minimum shares
        minimumShare = initData.threshold;

        // point to Hats Protocol
        HATS = IHats(hatsProtocol);

        // point access control functionality to Hats protocol
        _changeHatsContract(hatsProtocol);

        // create/mint Hats
        if (
            initData.topHatWearer != address(0) &&
            initData.topHatId != 0 &&
            HATS.isWearerOfHat(initData.topHatWearer, initData.topHatId)
        ) {
            // todo: add logic for existing topHat

            return;
        } else {
            _buildNewHatTree(caller_, initData.admin1, initData.admin2);
        }

        // set the minimum stake requirement
        _setMinimumStake(initData.assetAmount);

        // set the cohort staking duration
        _setMaxDuration(initData.stakeDuration);

        // set the cohort token's base uri
        _setBaseUri(initData.baseUri);
    }

    /*************************
     MODIFIERS
     *************************/

    /**
     * @dev Modifier for preventing calls from contracts
     * Safety feature for preventing malicious contract call backs
     */
    modifier callerIsUser() {
        // for testing in Forge: disable
        // require(tx.origin == msg.sender, "The caller is another contract!");
        _;
    }

    /**
     * @dev Modifier for enforcing function callable from DAO members only
     * Allows decentralized control by DAO members
     */
    modifier onlyMember() {
        _checkMember();
        _;
    }

    /*************************
     USER FUNCTIONS
     *************************/

    /**
     * @dev Allows users to join the DAO initiation
     * @param user the address which will be activated for the cohort
     * Stakes required tokens and mints soul bound token
     */
    function joinInitiation(address user) public callerIsUser {
        // enforce time and size contraints
        require(block.timestamp <= joinEndTime, "This cohort is now closed");
        require(
            _tokenIdCounter.current() <= cohortSize,
            "This cohort is already full"
        );

        // enforce the initiate or sponsor transfers correct tokens to the contract
        require(_stake(user), "Staking failed!");

        // issue a soul bound token
        _soulBind(user);
    }

    /**
     * @dev Allows DAO members to claim their initiation stake
     */
    function claimStake() external onlyMember {
        require(_claim(), "Claim failed!");
    }

    /**
     * @dev Allows initiates to log permanent feedback data on-chain
     * @param feedback "Developers do something!"
     * Doesn't change contract state; simply passes call-data through an event
     */
    function cryForHelp(string calldata feedback) public {
        require(balanceOf(msg.sender) == 1, "Only cohort participants!");

        emit Feedback(msg.sender, treasury, feedback);
    }

    function checkStake(address user) external returns (uint256) {
        return _staked[user];
    }

    /*************************
     ACCESS CONTROL FUNCTIONS
     *************************/

    /**
     * @dev Claims the life force of failed initiates for the dao
     * @param failedInitiates an array of user's who have failed to join the DAO
     */
    function sacrifice(address[] calldata failedInitiates)
        public
        onlyRole(ADMIN)
    {
        _darkRitual(failedInitiates);
    }

    /**
     * @dev Allows DAO members to change the staking requirement
     * @param newMinimumStake the minimum quantity of tokens a user must stake to join the cohort
     */
    function setMinimumStake(uint256 newMinimumStake) external onlyRole(ADMIN) {
        _setMinimumStake(newMinimumStake);
    }

    /**
     * @dev Allows changing the DAO member share threshold
     * @param newShareThreshold the number of shares required to be considered a DAO member
     */
    function setShareThreshold(uint256 newShareThreshold)
        external
        onlyRole(ADMIN)
    {
        // enforce that the minimum share threshold isn't zero
        require(
            newShareThreshold > 0,
            "Minimum shares must be greater than zero!"
        );

        // set the minimum number of DAO shares required to graduate
        minimumShare = newShareThreshold;

        // log data for the new minimum share threshold
        emit ChangedShares(newShareThreshold);
    }

    /**
     * @dev Allows changing the maximum initiation duration
     * @param newMaxTime the length in seconds until an initiate's stake is forfeit
     */
    function setMaxDuration(uint256 newMaxTime) external onlyRole(SUPER_ADMIN) {
        _setMaxDuration(newMaxTime);
    }

    function changeJoinSizeLimit(uint256 _cohortSize)
        external
        onlyRole(SUPER_ADMIN)
    {
        cohortSize = _cohortSize;
    }

    function extendJoinTimeLimit(uint256 _extension)
        external
        onlyRole(SUPER_ADMIN)
    {
        joinEndTime = joinEndTime + _extension;
    }

    /*************************
     PRIVATE OR INTERNAL
     *************************/

    function _setMinimumStake(uint256 newMinimumStake) internal {
        // enforce that the minimum stake isn't zero
        require(
            newMinimumStake > 0,
            "Minimum stake must be greater than zero!"
        );

        // set the minimum staking requirement
        minimumStake = newMinimumStake;

        //  new staking requirement data
        emit ChangedStake(newMinimumStake);
    }

    function _setMaxDuration(uint256 newMaxTime) internal virtual {
        // enforce that the minimum time is greater than 1 week
        require(newMaxTime > 0, "Minimum duration must be greater than 0!");

        // set the maximum length of time for initiations
        maximumTime = newMaxTime;

        // log the new duration before stakes can be slashed
        emit ChangedTime(newMaxTime);
    }

    /**
     * @dev Sets base URI during initialization
     * @param baseURI the base uri for accessing token metadata
     */
    function _setBaseUri(string calldata baseURI) internal virtual {
        __baseURI = baseURI;
    }

    /**
     * @dev Stakes the user's tokens
     * @param _user the address to activate for the cohort
     */
    function _stake(address _user) internal virtual returns (bool) {
        // enforce that the initiate hasn't previously staked
        require(balanceOf(_user) == 0, "Already joined the initiation!");

        // change the initiate's stake total
        _staked[_user] = minimumStake;

        // set the initiate's deadline
        deadlines[_user] = block.timestamp + maximumTime;

        return _token.transferFrom(msg.sender, address(this), minimumStake);
    }

    /**
     * @dev Claims the successful new members stake
     */
    function _claim() internal virtual returns (bool) {
        address msgSender = msg.sender;
        // enforce that the initiate has stake
        require(_staked[msgSender] > 0, "User has no stake!!");

        // store the user's balance
        uint256 balance = _staked[msgSender];

        // delete the balance
        delete _staked[msgSender];

        // delete the deadline timestamp
        delete deadlines[msgSender];

        // log data for this successful claim
        emit Claim(msgSender, balance);

        // return the new member's original stake
        return _token.transfer(msgSender, balance);
    }

    /**
     * @dev Mints soul bound tokens to the initiate
     * @param _user the recipient of the cohort SBT
     */
    function _soulBind(address _user) internal virtual {
        // store the current token counter
        uint256 tokenId = _tokenIdCounter.current();

        // log the initiation data
        emit Initiation(
            _user,
            msg.sender,
            tokenId,
            minimumStake,
            deadlines[_user]
        );

        // increment the token counter
        _tokenIdCounter.increment();

        // mint the user's soul bound initiation token
        _mint(_user, tokenId);
    }

    /**
     * @dev Claims failed initiate tokens for the DAO
     * @param _failedInitiates an array of user's who have failed to join the DAO
     */
    function _darkRitual(address[] calldata _failedInitiates) internal virtual {
        // the total amount of blood debt
        uint256 total;

        for (uint256 i = 0; i < _failedInitiates.length; ++i) {
            // store each initiate's address
            address initiate = _failedInitiates[i];

            // access each initiate's starting time
            uint256 deadline = deadlines[initiate];

            if (block.timestamp > deadline && _staked[initiate] > 0) {
                // access each initiate's balance
                uint256 balance = _staked[initiate];

                // calculate the total blood debt
                total += balance;

                // log sacrifice data
                emit Sacrifice(initiate, balance, msg.sender);

                // remove the sacrifice's balance
                delete _staked[initiate];

                // remove the sacrifice's starting time
                delete deadlines[initiate];
            } else {
                continue;
            }
        }

        // drain the life force from the sacrifice
        require(_token.transfer(treasury, total), "Failed Sacrifice!");

        // increase the slasher's essence
        totalSlash[msg.sender] += total;
    }

    /**
     * @dev Authenticates users through the DAO contract
     */
    function _checkMember() internal virtual {
        // access membership data from the DAO
        MolochDAO.Member memory member = dao.members(msg.sender);

        // access the user's total shares
        uint256 shares = member.shares;

        // enforce that the user is a member
        require(shares >= minimumShare, "You must be a member!");
    }

    /**
     * @dev Creates a new topHat, build Access Control tree,
     * and transfers topHat to DAO
     */
    function _buildNewHatTree(
        address _deployer,
        address _admin1,
        address _admin2
    ) internal virtual {
        topHat = HATS.mintTopHat(address(this), "ROM TopHat", "");

        // super-admin privileges: grant/revoke other admin, access control
        superAdminHat = HATS.createHat(
            topHat,
            "ROM Super-Admin",
            1,
            address(dao),
            address(dao),
            true,
            ""
        );

        // admin privileges: access control
        // 1 hat for address(this) + additional hats for number of admin
        adminHat = HATS.createHat(
            superAdminHat,
            "ROM Admin",
            3,
            _deployer,
            _deployer,
            true,
            ""
        );

        /**
         * @dev Mint superAdmin & admin hats to Deployer
         * DAO can grant/revoke superAdmin (after topHat is transferred below)
         * Deployer can grant/revoke other admin
         */
        HATS.mintHat(superAdminHat, _deployer);
        HATS.mintHat(adminHat, _deployer);

        if (_admin1 != address(0)) {
            HATS.mintHat(adminHat, _admin1);
        }
        if (_admin2 != address(0)) {
            HATS.mintHat(adminHat, _admin2);
        }

        // grant Hat Access Control roles
        _grantRole(SUPER_ADMIN, superAdminHat);
        _grantRole(ADMIN, adminHat);

        HATS.transferHat(topHat, address(this), address(dao));
    }

    /*************************
     VIEW AND PURE FUNCTIONS
     *************************/

    /**
     * @dev returns the user's deadline for onboarding
     */
    function getDeadline(address user) public view returns (uint256 deadline) {
        return deadlines[user];
    }

    /**
     * @dev returns the user's member status
     */
    function isMember(address user) public view returns (bool memberStatus) {
        // access membership data from the DAO
        MolochDAO.Member memory member = dao.members(user);

        // access the user's total shares
        uint256 shares = member.shares;

        if (shares >= minimumShare) {
            return true;
        } else {
            return false;
        }
    }

    /*************************
     OVERRIDES
     *************************/

    function _baseURI() internal view override returns (string memory) {
        return __baseURI;
    }

    // Cohort NFTs cannot be transferred
    function _transfer(
        address from,
        address to,
        uint256 tokenId
    ) internal virtual override {
        revert();
    }

    // The following functions are overrides required by Solidity.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
