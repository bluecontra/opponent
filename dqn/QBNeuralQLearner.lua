local nql = torch.class('dqn.QBNeuralQLearner')


function nql:__init(args)
    self.state_dim  = args.state_dim -- State dimensionality.
    self.feat_groups = args.feat_groups
    self.ans_size = args.ans_size
    self.actions    = args.actions
    self.n_actions  = #self.actions
    self.verbose    = args.verbose
    self.best       = args.best

    --- epsilon annealing
    self.ep_start   = args.ep or 1
    self.ep         = self.ep_start -- Exploration probability.
    self.ep_end     = args.ep_end or self.ep
    self.ep_endt    = args.ep_endt or 1000000

    ---- learning rate annealing
    self.lr_start       = args.lr or 0.01 --Learning rate.
    self.lr             = self.lr_start
    self.lr_end         = args.lr_end or self.lr
    self.lr_endt        = args.lr_endt or 1000000
    self.wc             = args.wc or 0  -- L2 weight cost.
    self.minibatch_size = args.minibatch_size or 1
    self.valid_size     = args.valid_size or 500

    --- Q-learning parameters
    self.discount       = args.discount or 0.99 --Discount factor.
    self.update_freq    = args.update_freq or 1
    -- Number of points to replay per learning step.
    self.n_replay       = args.n_replay or 1
    -- Number of steps after which learning starts.
    self.learn_start    = args.learn_start or 0
     -- Size of the transition table.
    self.replay_memory  = args.replay_memory or 1000000
    self.hist_len       = args.hist_len or 1
    self.rescale_r      = args.rescale_r
    self.max_reward     = args.max_reward
    self.min_reward     = args.min_reward
    self.clip_delta     = args.clip_delta
    self.target_q       = args.target_q
    self.bestq          = 0

    self.gpu            = args.gpu

    self.ncols          = args.ncols or 1  -- number of color channels in input
    self.preproc        = args.preproc  -- name of preprocessing network
    self.histType       = args.histType or "linear"  -- history type to use
    self.histSpacing    = args.histSpacing or 1
    self.nonTermProb    = args.nonTermProb or 1
    self.bufferSize     = args.bufferSize or 512

    self.transition_params = args.transition_params or {}


    -- check whether there is a network file
    if args.network ~= nil then
        self.network = args.network
        if not (type(self.network) == 'string') then
            error("The type of the network provided in NeuralQLearner" ..
                  " is not a string!")
        end

        local msg, err = pcall(require, self.network)
        if not msg then
            -- try to load saved agent
            local err_msg, exp = pcall(torch.load, self.network)
            if not err_msg then
                error("Could not find network file ")
            end
            if self.best and exp.best_model then
                print('Loading saved best Agent Network from ' .. self.network)
                self.network = exp.best_model
            else
                print('Loading saved Agent Network from ' .. self.network)
                self.network = exp.model
            end
        else
            print('Creating Agent Network from ' .. self.network)
            self.network = err
            self.network = self:network()
        end
    else
        self.network = self:createNetwork()
    end

    if self.gpu and self.gpu >= 0 then
        self.network:cuda()
    else
        self.network:float()
    end

    -- Load preprocessing network.
    if self.preproc ~= nil then
        if not (type(self.preproc == 'string')) then
            error('The preprocessing is not a string')
        end
        msg, err = pcall(require, self.preproc)
        if not msg then
            error("Error loading preprocessing net")
        end
        self.preproc = err
        self.preproc = self:preproc()
        self.preproc:float()
    end

    if self.gpu and self.gpu >= 0 then
        self.network:cuda()
        self.tensor_type = torch.CudaTensor
    else
        self.network:float()
        self.tensor_type = torch.FloatTensor
    end

    -- Create transition table.
    ---- assuming the transition table always gets floating point input
    ---- (Foat or Cuda tensors) and always returns one of the two, as required
    ---- internally it always uses ByteTensors for states, scaling and
    ---- converting accordingly
    local transition_args = {
        stateDim = self.state_dim, numActions = self.n_actions,
        histLen = self.hist_len, gpu = self.gpu,
        maxSize = self.replay_memory, histType = self.histType,
        histSpacing = self.histSpacing, nonTermProb = self.nonTermProb,
        bufferSize = self.bufferSize
    }

    self.transitions = dqn.TransitionTable(transition_args)

    self.numSteps = 0 -- Number of perceived states.
    self.lastState = nil
    self.lastAction = nil
    self.v_avg = 0 -- V running average.
    self.tderr_avg = 0 -- TD error running average.

    self.q_max = 1
    self.r_max = 1

    self.w, self.dw = self.network:getParameters()
    self.dw:zero()

    self.deltas = self.dw:clone():fill(0)

    self.tmp= self.dw:clone():fill(0)
    self.g  = self.dw:clone():fill(0)
    self.g2 = self.dw:clone():fill(0)

    if self.target_q then
        self.target_network = self.network:clone()
    end
end


function nql:reset(state)
    if not state then
        return
    end
    self.best_network = state.best_network
    self.network = state.model
    self.w, self.dw = self.network:getParameters()
    self.dw:zero()
    self.numSteps = 0
    print("RESET STATE SUCCESFULLY")
end


function nql:preprocess(rawstate)
    if self.preproc then
        return self.preproc:forward(rawstate:float())
                    :clone():reshape(self.state_dim)
    end

    return rawstate
end

function nql:getQUpdate(args)
    local s, a, r, s2, term, delta
    local q, q2, q2_max

    s = self:state_to_input(args.s)
    a = args.a
    r = args.r
    s2 = self:state_to_input(args.s2)
    term = args.term

    -- The order of calls to forward is a bit odd in order
    -- to avoid unnecessary calls (we only need 2).

    -- delta = r + (1-terminal) * gamma * max_a Q(s2, a) - Q(s, a)
    term = term:clone():float():mul(-1):add(1)

    local target_q_net
    if self.target_q then
        target_q_net = self.target_network
    else
        target_q_net = self.network
    end

    -- Compute max_a Q(s_2, a).
    q2_max = target_q_net:forward(s2):float():max(2)

    -- Compute q2 = (1-terminal) * gamma * max_a Q(s2, a)
    q2 = q2_max:clone():mul(self.discount):cmul(term)

    delta = r:clone():float()

    if self.rescale_r then
        delta:div(self.r_max)
    end
    delta:add(q2)

    -- q = Q(s,a)
    local q_all = self.network:forward(s):float()
    q = torch.FloatTensor(q_all:size(1))
    for i=1,q_all:size(1) do
        q[i] = q_all[i][a[i]]
    end
    delta:add(-1, q)

    if self.clip_delta then
        delta[delta:ge(self.clip_delta)] = self.clip_delta
        delta[delta:le(-self.clip_delta)] = -self.clip_delta
    end

    local targets = torch.zeros(self.minibatch_size, self.n_actions):float()
    for i=1,math.min(self.minibatch_size,a:size(1)) do
        targets[i][a[i]] = delta[i]
    end

    if self.gpu >= 0 then targets = targets:cuda() end

    return targets, delta, q2_max
end


function nql:qLearnMinibatch()
    -- Perform a minibatch Q-learning update:
    -- w += alpha * (r + gamma max Q(s2,a2) - Q(s,a)) * dQ(s,a)/dw
    assert(self.transitions:size() > self.minibatch_size)

    local s, a, r, s2, term = self.transitions:sample(self.minibatch_size)
    --print(s:narrow(2, 1, 10), a[1], r[1], s2:narrow(2, 1, 10), term[1])

    local targets, delta, q2_max = self:getQUpdate{s=s, a=a, r=r, s2=s2,
        term=term, update_qmax=true}

    -- zero gradients of parameters
    self.dw:zero()

    -- get new gradient
    s = self:state_to_input(s)
    self.network:backward(s, targets)

    -- clip gradients 
    --self.dw:clamp(-5, 5)

    -- add weight cost to gradient
    self.dw:add(-self.wc, self.w)

    -- compute linearly annealed learning rate
    local t = math.max(0, self.numSteps - self.learn_start)
    self.lr = (self.lr_start - self.lr_end) * (self.lr_endt - t)/self.lr_endt +
                self.lr_end
    self.lr = math.max(self.lr, self.lr_end)

    -- use gradients
    self.g:mul(0.95):add(0.05, self.dw)
    self.tmp:cmul(self.dw, self.dw)
    self.g2:mul(0.95):add(0.05, self.tmp)
    self.tmp:cmul(self.g, self.g)
    self.tmp:mul(-1)
    self.tmp:add(self.g2)
    self.tmp:add(0.01)
    self.tmp:sqrt()

    --rmsprop
    --local smoothing_value = 1e-8
    --self.tmp:cmul(self.dw, self.dw)
    --self.g:mul(0.9):add(0.1, self.tmp)
    --self.tmp = torch.sqrt(self.g)
    --self.tmp:add(smoothing_value)  --negative learning rate

    -- accumulate update
    self.deltas:mul(0):addcdiv(self.lr, self.dw, self.tmp)
    self.w:add(self.deltas)
end


function nql:sample_validation_data()
    local s, a, r, s2, term = self.transitions:sample(self.valid_size)
    self.valid_s    = s:clone()
    self.valid_a    = a:clone()
    self.valid_r    = r:clone()
    self.valid_s2   = s2:clone()
    self.valid_term = term:clone()
end


function nql:compute_validation_statistics()
    local targets, delta, q2_max = self:getQUpdate{s=self.valid_s,
        a=self.valid_a, r=self.valid_r, s2=self.valid_s2, term=self.valid_term}

    self.v_avg = self.q_max * q2_max:mean()
    self.tderr_avg = delta:clone():abs():mean()
end


function nql:perceive(reward, rawstate, terminal, testing, testing_ep, priority)
    -- Preprocess state (will be set to nil if terminal)
    local state = self:preprocess(rawstate):float()
    local curState

    if self.max_reward then
        reward = math.min(reward, self.max_reward)
    end
    if self.min_reward then
        reward = math.max(reward, self.min_reward)
    end
    if self.rescale_r then
        self.r_max = math.max(self.r_max, math.abs(reward))
    end

    self.transitions:add_recent_state(state, terminal)

    local currentFullState = self.transitions:get_recent()

    --Store transition s, a, r, s'
    if self.lastState and not testing then
        --print('add transition:')
        --print(self.lastState[self.state_dim], self.lastAction, reward, self.lastTerminal)
        self.transitions:add(self.lastState, self.lastAction, reward,
                             self.lastTerminal, priority)
    end

    if self.numSteps == self.learn_start+1 and not testing then
        self:sample_validation_data()
    end

    curState= self.transitions:get_recent()

    -- Select action
    local actionIndex = 1
    if not terminal then
        actionIndex = self:eGreedy(curState, testing_ep)
    end

    self.transitions:add_recent_action(actionIndex)

    --Do some Q-learning updates
    if self.numSteps > self.learn_start and not testing and
        self.numSteps % self.update_freq == 0 then
        for i = 1, self.n_replay do
            self:qLearnMinibatch()
        end
    end

    if not testing then
        self.numSteps = self.numSteps + 1
    end

    self.lastState = state:clone()
    self.lastAction = actionIndex
    self.lastTerminal = terminal

    if self.target_q and self.numSteps % self.target_q == 1 then
        self.target_network = self.network:clone()
    end

    if not terminal then
        return actionIndex
    else
        return 0
    end
end


function nql:eGreedy(state, testing_ep)
    self.ep = testing_ep or (self.ep_end +
                math.max(0, (self.ep_start - self.ep_end) * (self.ep_endt -
                math.max(0, self.numSteps - self.learn_start))/self.ep_endt))
    -- Epsilon greedy
    if torch.uniform() < self.ep then
        return torch.random(1, self.n_actions)
    else
        return self:greedy(state)
    end
end


function nql:greedy(state)
    if self.gpu >= 0 then
        state = state:cuda()
    end
   
    local s = self:state_to_input(state)
    local q = self.network:forward(s):float():squeeze()
    local maxq = q[1]
    local besta = {1}

    -- Evaluate all other actions (with random tie-breaking)
    for a = 2, self.n_actions do
        if q[a] > maxq then
            besta = { a }
            maxq = q[a]
        elseif q[a] == maxq then
            besta[#besta+1] = a
        end
    end
    self.bestq = maxq

    local r = torch.random(1, #besta)

    self.lastAction = besta[r]

    return besta[r]
end


function nql:createNetwork()
    local n_hid = 128
    local mlp = nn.Sequential()
    mlp:add(nn.Linear(self.state_dim, n_hid))
    mlp:add(nn.Rectifier())
    mlp:add(nn.Linear(n_hid, n_hid))
    mlp:add(nn.Rectifier())
    mlp:add(nn.Linear(n_hid, self.n_actions))

    return mlp
end

function nql:state_to_input(state)
    return state
    --return state:narrow(2, self.feat_groups.default.offset, self.feat_groups.default.size)
            --state:select(2, self.feat_groups.pred.offset)
        
end

function nql:createNetwork2()
    local n_hid = 128
    local pred_nhid = 50
    local inputs = {}
    table.insert(inputs, nn.Identity()())
    --table.insert(inputs, nn.Identity()())
    --local pred_emb = nn.LookupTable(self.ans_size, pred_nhid)(inputs[2])
    --local join = nn.JoinTable(2)({inputs[1], pred_emb})
    --local h = nn.Linear(self.feat_groups.default.size+pred_nhid, n_hid)(join)
    local h = nn.Linear(self.feat_groups.default.size, n_hid)(inputs[1])
    h = nn.Rectifier()(h)
    h = nn.Rectifier()(nn.Linear(n_hid, n_hid)(h))
    local logsoft = nn.LogSoftMax()(nn.Linear(n_hid, self.n_actions)(h))
    local outputs = {}
    table.insert(outputs, logsoft)
    return nn.gModule(inputs, outputs)
end

function nql:createNetwork2()
    local n_hid = 128
    local mlp = nn.Sequential()
    -- get different parts of the input
    local concat = nn.ConcatTable()
    concat:add(nn.Narrow(2, self.feat_groups.default.offset, self.feat_groups.default.size))
    --concat:add(nn.Narrow(2, self.feat_groups.pred.offset, self.feat_groups.pred.size))
    concat:add(nn.Select(2, self.feat_groups.pred.offset))
    mlp:add(concat)
    -- transformation for each group
    local parallel = nn.ParallelTable()
    parallel:add(nn.Identity())
    local pred_nhid = 50
    --local pred_mlp = nn.Sequential()
    --pred_mlp:add(MultiHot(self.ans_size))
    --pred_mlp:add(nn.Linear(self.ans_size, pred_nhid))
    --parallel:add(pred_mlp)
    parallel:add(nn.LookupTable(self.ans_size, pred_nhid))
    mlp:add(parallel)
    -- join two parts
    mlp:add(nn.JoinTable(2))
    mlp:add(nn.Linear(self.feat_groups.default.size+pred_nhid, n_hid))
    --mlp:add(nn.Rectifier())
    --mlp:add(nn.Linear(n_hid, n_hid))
    mlp:add(nn.Rectifier())
    mlp:add(nn.Linear(n_hid, self.n_actions))
    return mlp
end


function nql:_loadNet()
    local net = self.network
    if self.gpu then
        net:cuda()
    else
        net:float()
    end
    return net
end


function nql:init(arg)
    self.actions = arg.actions
    self.n_actions = #self.actions
    self.network = self:_loadNet()
    -- Generate targets.
    self.transitions:empty()
end


function nql:report()
    print(get_weight_norms(self.network))
    print(get_grad_norms(self.network))
end