function char_rnn(input_fname)
% Convert from Andrej's Python NumPY gist to Matlab
% https://gist.github.com/karpathy/d4dee566867f8291f086
%

%% Gather data
if nargin == 0
    input_fname = 'ex1.txt';
end
fid = fopen(input_fname, 'r');

% Load contents of text file
data = textscan(fid, '%c', 'whitespace', '', 'delimiter', '\n');
fclose(fid);

% integer data (ASCII values, easier to get one-hot vectors with arrayfun :))
idata = double(data{1})';

% integer unique characters (ASCII).  
% Used to get dictionary for 1-of-k encoding
ichars = unique(idata);
fprintf('%d unique characters [%s] in data.\n', length(ichars), string(ichars));

%% Setup parameters
%%% Data parameters

% Size of unique number of characters
vocab_size = length(ichars);

% Total input data size
data_size  = length(idata);

%%% Hyperparameters
hidden_size = 100;      % size of hidden layer of neurons
seq_length  = 25;        % number of RNN unroll steps
learning_rate = 1e-1;   % learning rate

%%% Initialize RNN model parameters - weights for bits
Wxh = randn(hidden_size, vocab_size)*0.01;    % weights: input to hidden
Whh = randn(hidden_size, hidden_size)*0.01;   % weights: hidden to hidden
Why = randn(vocab_size, hidden_size)*0.01;    % weights: hidden to output
bh  = zeros(hidden_size, 1);                   % bias: hidden
by  = zeros(vocab_size, 1);                    % bias: output

%%% Memory variables for adagrad - weights for bits
mWxh = zeros(size(Wxh));
mWhh = zeros(size(Whh));
mWhy = zeros(size(Why));
mbh  = zeros(size(bh));
mby  = zeros(size(by));

%% Start learning
epochs = 0; % initialise num epochs
n = 0;      % iteration counter
p = 1;      % data pointer
smooth_loss = -log(1/vocab_size) * seq_length;      % loss at iter=0
while true
    %%% reset after one pass over all data OR at the first iteration
    if p+seq_length >= data_size || n == 0
        epochs = epochs + 1;
        fprintf('>>>> Starting %d epoch... \n', epochs);
        hprev = zeros(hidden_size, 1);      % reset RNN memory
        p = 1;                              % move data pointer to start
        %if smooth_loss < 3
        %    break;
        %end
    end

    %%% get inputs and targets
    % prepare inputs (we're sweeping from left to right in steps seq_length=25 long)
    % char_to_ix (1 of k encoding)
    idatapart = idata(p : p+seq_length-1);
    inputs = arrayfun(@(x) ichars == x, idatapart, 'UniformOutput', false);
    %inputs = arrayfun(@(x) ichars == x, idatapart);
    inputs = double(cat(1, inputs{:})');
    
    %Target should be next character in sequence
    targets = arrayfun(@(x) find(ichars == x), idata(p+1 : p+seq_length));

    %%% sample from model
    if mod(n, 100) == 0
        sample_ix = RNN_sample(hprev, inputs(:, 1), 200);
        text = char(ichars(sample_ix));
        fprintf(2, '--- Sampled text @ iter = %5d | loss = %.2f ---\n', n, smooth_loss);
        fprintf('%s\n-----------\n\n', text);
    end

    %%% forward seq_length characters and get gradients
    [loss, grads, hprev] = RNN_loss_function(inputs, targets, hprev);
    smooth_loss = smooth_loss * 0.999 + loss * 0.001;
    % gradients contain: dWxh, dWhh, dWhy, dbh, dby

    %%% update parameters with Adagrad
    [mWxh, Wxh] = adagrad_update(learning_rate, Wxh, grads.dWxh, mWxh);
    [mWhh, Whh] = adagrad_update(learning_rate, Whh, grads.dWhh, mWhh);
    [mWhy, Why] = adagrad_update(learning_rate, Why, grads.dWhy, mWhy);
    [mbh , bh ] = adagrad_update(learning_rate, bh , grads.dbh ,  mbh);
    [mby , by ] = adagrad_update(learning_rate, by , grads.dby ,  mby);

    p = p + seq_length;
    n = n + 1;
end


%% Loss function
function [loss, grads, hret] = RNN_loss_function(inputs, targets, hprev)
% inputs  \in {0,1} (vocab_size, seq_length) one-hot encoded  --> already "xs" in min-char-rnn.py
% targets \in {1:vocab_size} (1, seq_length)
% hprev   \in R (hidden_size, 1)

    loss = 0;
    hs = [hprev, zeros(hidden_size, seq_length)];
    ys = zeros(vocab_size, seq_length);
    ps = zeros(vocab_size, seq_length);

    %%% forward pass
    nFP = size(inputs, 2);
    for t = 1:nFP % iterate seq_length
        
        % update next hidden state using inputs and current hidden state.
        x2h = Wxh * inputs(:, t);
        h2h = Whh * hs(:, t);
        hs(:, t+1) = tanh(x2h + h2h + bh);
        
        % get prediction scores
        h2y = Why * hs(:, t+1);
        ys(:, t) = h2y + by;
        
        % soft-max and normalise
        ps(:, t) = exp(ys(:, t)) / sum(exp(ys(:, t)));
        
        % cross-entropy loss
        loss = loss - log(ps(targets(t), t));
    end
    
    %%% backward pass
    grads = struct('dWxh', zeros(size(Wxh)), ...
                   'dWhh', zeros(size(Whh)), ...
                   'dWhy', zeros(size(Why)), ...
                   'dbh' , zeros(size(bh )), ...
                   'dby' , zeros(size(by )));
               
    dhnext = zeros(hidden_size, 1);
    for t = size(inputs, 2):-1:1
        dy = ps(:, t);
        dy(targets(t)) = dy(targets(t)) - 1; % backprop for y
        grads.dWhy = grads.dWhy + dy * hs(:, t+1)';
        grads.dby  = grads.dby  + dy;

        % backprop into h
        dh = Why' * dy + dhnext;
        dhraw = (1 - (hs(:, t+1) .* hs(:, t+1))) .* dh;     % backprop tanh non-linearity

        grads.dWhh = grads.dWhh + dhraw * hs(:, t)';
        grads.dbh  = grads.dbh  + dhraw;

        grads.dWxh = grads.dWxh + dhraw * inputs(:, t)';

        dhnext = Whh' * dhraw;
    end

    % clip and prevent exploding gradients
    grads.dWxh = max(min(grads.dWxh, 1), -1);
    grads.dWhh = max(min(grads.dWhh, 1), -1);
    grads.dWhy = max(min(grads.dWhy, 1), -1);
    grads.dbh  = max(min(grads.dbh,  1), -1);
    grads.dby  = max(min(grads.dby,  1), -1);

    %%% return
    hret = hs(:, end);
end


%% Sampling function
function ixes = RNN_sample(h, seed, nsample)
% hprev  \in R (hidden_size, 1)
% seed   \in {0,1} (vocab_size, 1)  initial seed character (one-hot encoded)
% nsample -- number of characters to sample

    ixes = zeros(1, nsample);
    
    for t = 1:nsample
        
        % update hidden state
        x2h = Wxh * seed;
        h2h = Whh * h;
        h   = tanh(x2h + h2h + bh);
        
        % get prediction scores
        h2y = Why * h;
        y   = h2y + by;
        
        % soft-max probabilities
        pr = exp(y) / sum(exp(y));
        assert(sum(pr) - 1 < 1e-10, 'SoftMax probabilities broken!');
        
        ixes(t) = numpy_random_choice(pr);
        
        seed = zeros(vocab_size, 1);
        seed(ixes(t)) = 1;
    end
end




end  % end char_rnn

%% Support functions
function [mem, param] = adagrad_update(learning_rate, param, dparam, mem)
    mem = mem + dparam .* dparam;
    param = param - learning_rate * dparam ./ sqrt(mem + 1e-8);
end


function pick = numpy_random_choice(probabilities)
%NUMPY_RANDOM_CHOICE
% Implements Python equivalent of numpy.random.choice()
%
%   probabilities: a list of probabilities summing up to 1	
%
% Example:
%     probabilities = [0; 0; 0.2; 0.6; 0.2; 0];
%     for k = 1:1000
%         X(k) = numpy_random_choice(probabilities);
%     end
%     hist(X, 1:6);
%

cdf = [0; cumsum(probabilities)];
pick = sum(cdf <= rand);

end
