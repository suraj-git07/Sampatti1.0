// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;


import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "contracts/SPTToken.sol";

/** this contract is basically work as a dao here any user are given a right to be a validator, 
          he just have to satake some Sampatti token 
  User can put here to validate his nft only after validation nft is minted
  IF nft request is decided to be rejected all the validators who verified the nft will be slashed(vice -versa)
**/

contract Sampatti is ReentrancyGuard {
    address public owneradd; // add of owner
    address public owner; // one who created the contract
    uint256 public chargeFee; // charge pay to raise a verification req
    uint256 public stakeFee; // min charge pay to become a validator
    uint256 public totalStaked = 0; // total staking of the system
    SPTToken public sptToken; // instance of Token

    using Counters for Counters.Counter;
    Counters.Counter private reqID; // counter for cases
    
    
    uint256 constant DECIMALS = 8;

    constructor(
        uint256 _fee,
        uint256 _stakeFee,
        SPTToken _token
    ) {
        owneradd = address(this);
        owner = msg.sender;
        chargeFee = _fee;
        stakeFee = _stakeFee;
        sptToken = _token;
    }

    modifier OwnerOnly() {
        require(msg.sender == owner, "owner not calling");
        _;
    }

    // Status of verification req filing enum
    enum Status {
        WAITING_FOR_APPROVAL,
        APPROVED,
        REJECTED
    }


    // struct of a verification request
    struct Request {
        uint256 reqID;
        address from;
        string name_req_for_owner;
        string uri; // ipfs uri for papers
        Status status; // status of the case
        address[] voters; // array of voters
        mapping(address => uint256) votings; // who voted

        mapping(address => bool) claims; // claims taken status
        bool final_decision; // final selected option
        uint256 finalisedAt; // unix time for case end time
        uint256 totalWinningVotes;
    }

    // struct for a voter
    struct Validator {
        address validator;
        bool option;
        uint256 votingPowerAllocated;
    }

    mapping(uint256 => Request) public requests; // requests
    mapping(address => bool) public validators; //  is voter
    mapping(address => uint256) public stakeHolders; // how much stake
    mapping(uint256 => Validator[]) public votemap; // reqID ==> array of Validators

    // reqFile event
    event ReqFile(
        address indexed _from,
        string _name,
        string _uri,
        uint256 _reqID
    );

     //  propose a request
    function proposeRequest(string memory _uri, string memory _name)
        public
        nonReentrant
    {
        
        //todo take user case fee
        sptToken.transferFrom(msg.sender, owner, chargeFee * (10**DECIMALS));
        reqID.increment();
        Request storage currReq = requests[reqID.current()];
        currReq.reqID = reqID.current();
        
        currReq.from = msg.sender;
        currReq.name_req_for_owner = _name;
        currReq.uri = _uri;
        currReq.status = Status.WAITING_FOR_APPROVAL;
        currReq.final_decision = false;
        currReq.finalisedAt = 0; // 0 because it is not started yet
        currReq.totalWinningVotes = 0; // total volume(value) of votes is 0 initially


        emit ReqFile(msg.sender, _name, _uri, reqID.current());
    }


    // function to become a validator
    function stake(uint256 stakeAmt) public {
        require(validators[msg.sender] == false, "already a voter");
        require(stakeAmt >= stakeFee *10**DECIMALS, "staking amt is not enough");
        sptToken.transferFrom(msg.sender, owner, stakeAmt);
        totalStaked = totalStaked + stakeAmt;
        stakeHolders[msg.sender] = stakeAmt;
        validators[msg.sender] = true;
    }


    function getStake(address user) public view returns (uint256) {
        return stakeHolders[user];
    }

    // function for voting on a request
    function voting(
        uint256 _reqId,
        bool option
    ) public {
        require(validators[msg.sender] == true, "you are not a voter");
        require(requests[_reqId].votings[msg.sender] == 0, "you already voted");
        Request storage currReq = requests[_reqId];
        require(currReq.status == Status.WAITING_FOR_APPROVAL, "case approved already");
        require(currReq.finalisedAt > block.timestamp, "case expired");

        currReq.votings[msg.sender] = 1;

        Validator memory currVote = Validator(
            msg.sender,
            option,
            getStake(msg.sender)
        );
        votemap[_reqId].push(currVote);
    }


    function endRequest(uint256 _reqId) public {
        require(
            requests[_reqId].finalisedAt <= block.timestamp,
            "voting in progress"
        );
        require(requests[_reqId].status == Status.WAITING_FOR_APPROVAL, "request approved");
        uint  yescase = 0;
        uint  nocase = 0;
        bool  result = false;
        
        for (uint256 i = 0; i < votemap[_reqId].length; i++) {
            
            if(votemap[_reqId][i].option==true){
                yescase++;
            }
            else{
                nocase++;
            }
               
        }
        if(yescase>nocase){
            requests[_reqId].status = Status.APPROVED;
            requests[_reqId].totalWinningVotes = yescase;
            requests[_reqId].final_decision = true;
            result = true;
        }
        else{
            requests[_reqId].status = Status.REJECTED;
            requests[_reqId].totalWinningVotes = nocase;
             requests[_reqId].final_decision = false;
            result = false;
        }


        address[] memory losers;
        uint256 loserCount = 0;
        for (uint256 i = 0; i < votemap[_reqId].length; i++) {
            // like asking 0 option == index of max which is also same as the option number
            if (votemap[_reqId][i].option != result) {
                losers[loserCount] = (votemap[_reqId][i].validator);
                loserCount++;
            }
        }

        for (uint256 i = 0; i < losers.length; i++) {
            stakeHolders[losers[i]] -= ((stakeHolders[losers[i]])/ 10);

            sptToken.burnFrom(losers[i], ((stakeHolders[losers[i]]) / 10));
        }
        requests[_reqId].finalisedAt = block.timestamp;

    }

    function claimStake(uint256 _reqId) public {
        require(requests[_reqId].status != Status.WAITING_FOR_APPROVAL, "case not finalised");

        require(requests[_reqId].votings[msg.sender] != 0, "you not voted");
        require(requests[_reqId].claims[msg.sender] == false, "already claimed");
        uint256 claim = (getVotes(_reqId, msg.sender).votingPowerAllocated *
            2 *
            chargeFee *
            10**DECIMALS) / requests[_reqId].totalWinningVotes;

        sptToken.transfer(msg.sender, claim);
        requests[_reqId].claims[msg.sender] = true;
    }

    function getVotes(uint256 _reqId, address add)
        public
        view
        returns (Validator memory)
    {
        //check if case finalised
        require(requests[_reqId].status != Status.WAITING_FOR_APPROVAL);

        Validator memory vote;
        for (uint256 i = 0; i < votemap[_reqId].length; i++) {
            if (votemap[_reqId][i].validator == add) {
                vote = votemap[_reqId][i];
            }
        }
        return vote;
    }

    function withdrawStake() public {
        require(validators[msg.sender], "you are not a voter");
        sptToken.transfer(owner, stakeHolders[msg.sender]);
        stakeHolders[msg.sender] = 0;
        validators[msg.sender] = false;
    }

}
