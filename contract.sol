
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract EmptyContract is ReentrancyGuard, Ownable {
    uint256 private _postIdCounter;
    uint256 private _commentIdCounter;

    // Constants packed
    int256 constant POST_REP = 10;
    int256 constant COMMENT_REP = 5;
    int256 constant VOTE_REP = 2;
    uint256 constant MAX_BATCH = 100;
    uint256 constant MAX_COMMENTS = 1000;
    int256 constant MIN_REP = -1_000_000;
    int256 constant MAX_REP = 1_000_000;

    struct Post {
        uint256 id;
        address author;
        string content;
        int256 votes;
        bool isActive;
    }

    struct Comment {
        uint256 id;
        uint256 postId;
        address author;
        string content;
        int256 votes;
        bool isActive;
    }

    struct VoteState {
        bool hasVoted;
        bool isUpvote;
        bool hasRevoked;
    }

    // Core batch result structures - simplified
    struct PostData {
        Post post;
        uint256 commentsCount;
        VoteState userVote;
        int256 authorRep;
    }

    struct UserStats {
        int256 reputation;
        bool isModerator;
        uint256 postsCount;
        uint256 commentsCount;
    }

    mapping(uint256 => Post) public posts;
    mapping(uint256 => Comment) public comments;
    mapping(uint256 => uint256[]) private postComments;
    mapping(address => mapping(uint256 => VoteState)) public postVotes;
    mapping(address => mapping(uint256 => VoteState)) public commentVotes;
    mapping(address => int256) public userReputation;
    mapping(address => bool) public moderators;
    mapping(address => uint256) private userPostCounts;
    mapping(address => uint256) private userCommentCounts;

    // Consolidated events
    event PostAction(uint256 indexed postId, address indexed user, string action, int256 newRep);
    event CommentAction(uint256 indexed commentId, uint256 indexed postId, address indexed user, string action, int256 newRep);
    event VoteAction(uint256 indexed itemId, address indexed voter, bool isPost, bool isUpvote, bool isRevoke);
    event ModeratorChanged(address indexed moderator, bool added);

    modifier onlyActivePost(uint256 postId) {
        require(posts[postId].id == postId && posts[postId].isActive, "Invalid post");
        _;
    }

    modifier onlyActiveComment(uint256 commentId) {
        require(comments[commentId].id == commentId && comments[commentId].isActive, "Invalid comment");
        _;
    }

    modifier onlyModerator() {
        require(moderators[msg.sender] || msg.sender == owner(), "Not moderator");
        _;
    }

    modifier notZeroAddress(address addr) {
        require(addr != address(0), "Zero address not allowed");
        _;
    }

    modifier validSender() {
        require(msg.sender != address(0), "Invalid sender");
        _;
    }

    constructor() Ownable() {
        require(msg.sender != address(0), "Invalid deployer");
        moderators[msg.sender] = true;
    }

    // Admin functions - consolidated with zero address validation
    function setModerator(address user, bool status) external onlyOwner notZeroAddress(user) {
        if (status) {
            require(!moderators[user], "Already moderator");
        } else {
            require(moderators[user] && user != owner(), "Cannot remove");
        }
        moderators[user] = status;
        emit ModeratorChanged(user, status);
    }

    function adminRemove(uint256 id, bool isPost, string calldata reason) external onlyModerator validSender {
        if (isPost) {
            require(posts[id].isActive, "Already removed");
            posts[id].isActive = false;
            emit PostAction(id, msg.sender, reason, 0);
        } else {
            require(comments[id].isActive, "Already removed");
            comments[id].isActive = false;
            emit CommentAction(id, comments[id].postId, msg.sender, reason, 0);
        }
    }

    // Internal helpers - optimized
    function _updateRep(address user, int256 amount) internal {
        require(user != address(0), "Invalid user");
        int256 newRep = userReputation[user] + amount;
        if (newRep > MAX_REP) newRep = MAX_REP;
        else if (newRep < MIN_REP) newRep = MIN_REP;
        userReputation[user] = newRep;
    }

    function _buildPostData(uint256 postId, address viewer) internal view returns (PostData memory) {
        Post storage post = posts[postId];
        return PostData({
            post: post,
            commentsCount: postComments[postId].length,
            userVote: viewer != address(0) ? postVotes[viewer][postId] : VoteState(false, false, false),
            authorRep: userReputation[post.author]
        });
    }

    function _buildUserStats(address user) internal view returns (UserStats memory) {
        return UserStats({
            reputation: userReputation[user],
            isModerator: moderators[user],
            postsCount: userPostCounts[user],
            commentsCount: userCommentCounts[user]
        });
    }

    // Batch operations - core functionality with validation
    function createPost(string calldata content) external nonReentrant validSender returns (uint256 postId, PostData memory postData, UserStats memory userStats) {
        require(bytes(content).length > 0 && bytes(content).length <= 10000, "Invalid content");

        _postIdCounter++;
        postId = _postIdCounter;

        posts[postId] = Post(postId, msg.sender, content, 0, true);
        userPostCounts[msg.sender]++;
        _updateRep(msg.sender, POST_REP);

        emit PostAction(postId, msg.sender, "created", userReputation[msg.sender]);

        return (postId, _buildPostData(postId, msg.sender), _buildUserStats(msg.sender));
    }

    function votePost(uint256 postId, bool isUpvote) external onlyActivePost(postId) nonReentrant validSender
        returns (PostData memory postData, UserStats memory voterStats, UserStats memory authorStats) {
        
        VoteState storage voteState = postVotes[msg.sender][postId];
        require(!voteState.hasVoted && !voteState.hasRevoked, "Cannot vote");
        
        Post storage post = posts[postId];
        require(post.author != msg.sender, "Cannot vote own post");
        require(post.author != address(0), "Invalid post author");

        // Update vote state first to prevent reentrancy
        voteState.hasVoted = true;
        voteState.isUpvote = isUpvote;

        if (isUpvote) {
            post.votes++;
            _updateRep(post.author, VOTE_REP);
        } else {
            post.votes--;
            _updateRep(post.author, -1);
        }

        emit VoteAction(postId, msg.sender, true, isUpvote, false);

        return (_buildPostData(postId, msg.sender), _buildUserStats(msg.sender), _buildUserStats(post.author));
    }

    function addComment(uint256 postId, string calldata content) external onlyActivePost(postId) nonReentrant validSender
        returns (uint256 commentId, PostData memory postData, UserStats memory userStats) {
        
        require(bytes(content).length > 0 && bytes(content).length <= 5000, "Invalid content");
        require(postComments[postId].length < MAX_COMMENTS, "Max comments reached");

        _commentIdCounter++;
        commentId = _commentIdCounter;

        comments[commentId] = Comment(commentId, postId, msg.sender, content, 0, true);
        postComments[postId].push(commentId);
        userCommentCounts[msg.sender]++;
        _updateRep(msg.sender, COMMENT_REP);

        emit CommentAction(commentId, postId, msg.sender, "created", userReputation[msg.sender]);

        return (commentId, _buildPostData(postId, msg.sender), _buildUserStats(msg.sender));
    }

    function voteComment(uint256 commentId, bool isUpvote) external onlyActiveComment(commentId) nonReentrant validSender
        returns (UserStats memory voterStats, UserStats memory authorStats) {
        
        VoteState storage voteState = commentVotes[msg.sender][commentId];
        require(!voteState.hasVoted && !voteState.hasRevoked, "Cannot vote");
        
        Comment storage comment = comments[commentId];
        require(comment.author != msg.sender, "Cannot vote own comment");
        require(comment.author != address(0), "Invalid comment author");

        // Update vote state first to prevent reentrancy
        voteState.hasVoted = true;
        voteState.isUpvote = isUpvote;

        if (isUpvote) {
            comment.votes++;
            _updateRep(comment.author, VOTE_REP);
        } else {
            comment.votes--;
            _updateRep(comment.author, -1);
        }

        emit VoteAction(commentId, msg.sender, false, isUpvote, false);

        return (_buildUserStats(msg.sender), _buildUserStats(comment.author));
    }

    // Feed and details - optimized with validation
    function getFeed(uint256 startId, uint256 batchSize, address viewer) external view returns (PostData[] memory) {
        require(batchSize > 0 && batchSize <= MAX_BATCH, "Invalid batch size");
        
        uint256 currentTotal = _postIdCounter;
        if (startId > currentTotal) return new PostData[](0);

        PostData[] memory temp = new PostData[](batchSize);
        uint256 count = 0;
        uint256 endId = startId + batchSize > currentTotal ? currentTotal : startId + batchSize;

        for (uint256 i = startId; i <= endId && count < batchSize; i++) {
            if (posts[i].id == i && posts[i].isActive) {
                temp[count] = _buildPostData(i, viewer);
                count++;
            }
        }

        PostData[] memory result = new PostData[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = temp[i];
        }
        return result;
    }

    function getPostDetails(uint256 postId, uint256 commentStart, uint256 commentBatch, address viewer) 
        external view returns (PostData memory postData, Comment[] memory commentsData, bool hasMore) {
        
        require(posts[postId].id == postId, "Post not found");
        require(commentBatch <= MAX_BATCH, "Batch too large");

        postData = _buildPostData(postId, viewer);
        uint256[] storage commentIds = postComments[postId];
        
        if (commentIds.length == 0 || commentStart >= commentIds.length) {
            return (postData, new Comment[](0), false);
        }

        uint256 endIdx = commentStart + commentBatch > commentIds.length ? commentIds.length : commentStart + commentBatch;
        Comment[] memory activeComments = new Comment[](endIdx - commentStart);
        uint256 count = 0;

        for (uint256 i = commentStart; i < endIdx; i++) {
            Comment storage comment = comments[commentIds[i]];
            if (comment.isActive) {
                activeComments[count] = comment;
                count++;
            }
        }

        Comment[] memory result = new Comment[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = activeComments[i];
        }

        return (postData, result, endIdx < commentIds.length);
    }

    // Vote revocation - fixed reentrancy vulnerability
    function revokeVote(uint256 id, bool isPost) external nonReentrant validSender {
        if (isPost) {
            VoteState storage vs = postVotes[msg.sender][id];
            require(vs.hasVoted && !vs.hasRevoked, "No valid vote to revoke");
            
            Post storage post = posts[id];
            require(post.id == id && post.isActive, "Invalid post");
            require(post.author != address(0), "Invalid post author");
            
            // Update vote state first to prevent reentrancy
            bool wasUpvote = vs.isUpvote;
            vs.hasVoted = false;
            vs.hasRevoked = true;
            
            // Then update post votes and reputation
            if (wasUpvote) {
                post.votes--;
                _updateRep(post.author, -VOTE_REP);
            } else {
                post.votes++;
                _updateRep(post.author, 1);
            }
            
            emit VoteAction(id, msg.sender, true, wasUpvote, true);
        } else {
            VoteState storage vs = commentVotes[msg.sender][id];
            require(vs.hasVoted && !vs.hasRevoked, "No valid vote to revoke");
            
            Comment storage comment = comments[id];
            require(comment.id == id && comment.isActive, "Invalid comment");
            require(comment.author != address(0), "Invalid comment author");
            
            // Update vote state first to prevent reentrancy
            bool wasUpvote = vs.isUpvote;
            vs.hasVoted = false;
            vs.hasRevoked = true;
            
            // Then update comment votes and reputation
            if (wasUpvote) {
                comment.votes--;
                _updateRep(comment.author, -VOTE_REP);
            } else {
                comment.votes++;
                _updateRep(comment.author, 1);
            }
            
            emit VoteAction(id, msg.sender, false, wasUpvote, true);
        }
    }

    // Content removal - with validation
    function removeContent(uint256 id, bool isPost) external nonReentrant validSender {
        if (isPost) {
            Post storage post = posts[id];
            require(post.author == msg.sender && post.isActive, "Cannot remove");
            post.isActive = false;
            _updateRep(msg.sender, -POST_REP);
            emit PostAction(id, msg.sender, "removed", userReputation[msg.sender]);
        } else {
            Comment storage comment = comments[id];
            require(comment.author == msg.sender && comment.isActive, "Cannot remove");
            comment.isActive = false;
            _updateRep(msg.sender, -COMMENT_REP);
            emit CommentAction(id, comment.postId, msg.sender, "removed", userReputation[msg.sender]);
        }
    }

    // Essential view functions with validation
    function getUserStats(address user) external view notZeroAddress(user) returns (UserStats memory) {
        return _buildUserStats(user);
    }

    function getTotals() external view returns (uint256 posts_, uint256 comments_) {
        return (_postIdCounter, _commentIdCounter);
    }
}
