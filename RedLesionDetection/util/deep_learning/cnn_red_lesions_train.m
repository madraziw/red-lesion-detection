function [net, stats] = cnn_red_lesions_train(net, imdb, getBatch, varargin)

opts.expDir = fullfile('data','exp') ;
opts.continue = true ;
opts.numSubBatches = 1 ;
opts.train = [] ;
opts.val = [] ;
opts.gpus = [] ;
opts.prefetch = false ;
opts.momentum = 0.9 ;
opts.randomSeed = 0 ;
opts.memoryMapFile = fullfile(tempdir, 'matconvnet.bin') ;
opts.profile = false ;
opts.conserveMemory = true ;
opts.backPropDepth = +inf ;
opts.sync = false ;
opts.cudnn = true ;
opts.errorFunction = 'multiclass' ;
opts.errorLabels = {} ;
opts.plotDiagnostics = false ;
opts.plotStatistics = true;
% Orlando and Blaschko parameters
opts.dataMean = [];
opts.batchSize = 256 ;
opts.numClasses = 2;
opts.weightDecay = 0.0005 ;
opts.minEpochs = 10;
opts.N = 5;
opts.maxEpochs = 200;
opts.convergenceThreshold = 1e-4;
opts.initialLearningRate = 0.05;
opts.lrDecayFactor = 1/2;
opts.learningRate = opts.initialLearningRate;
opts.decayLRThreshold = 1e-3;
opts.numEpochs = opts.minEpochs;
opts.p_dropout = 0;
opts.fc_layer = 64;
opts = vl_argparse(opts, varargin) ;


if gpuDeviceCount > 0
     opts.gpus = 1;
     imdb.meta.beta = (imdb.meta.beta);
     imdb.meta.gamma = (imdb.meta.gamma);
end

if ~exist(opts.expDir, 'dir'), mkdir(opts.expDir) ; end
if isempty(opts.train), opts.train = find(imdb.images.set==1) ; end
if isempty(opts.val), opts.val = find(imdb.images.set==2) ; end
if isnan(opts.train), opts.train = [] ; end
if isnan(opts.val), opts.val = [] ; end

% -------------------------------------------------------------------------
%                                                            Initialization
% -------------------------------------------------------------------------

% Copy beta and gamma to the net so we can use it at the time of training
% the net with the class balanced softmax loss
net.meta.beta = imdb.meta.beta;
net.meta.gamma = imdb.meta.gamma;

net = vl_simplenn_tidy(net); % fill in some eventually missing values
net.layers{end-1}.precious = 1; % do not remove predictions, used for error
vl_simplenn_display(net, 'batchSize', opts.batchSize) ;

evaluateMode = isempty(opts.train) ;
if ~evaluateMode
  for i=1:numel(net.layers)
    if isfield(net.layers{i}, 'weights')
      J = numel(net.layers{i}.weights) ;
      if ~isfield(net.layers{i}, 'learningRate')
        net.layers{i}.learningRate = ones(1, J, 'single') ;
      end
      if ~isfield(net.layers{i}, 'weightDecay')
        net.layers{i}.weightDecay = ones(1, J, 'single') ;
      end
    end
  end
end

% setup error calculation function
hasError = true ;
if isstr(opts.errorFunction)
  opts.errorFunction_string = opts.errorFunction;
  switch opts.errorFunction
    case 'none'
      opts.errorFunction = @error_none ;
      hasError = false ;
    case 'multiclass'
      opts.errorFunction = @error_multiclass ;
      if isempty(opts.errorLabels), opts.errorLabels = {'top1err'} ; end  
    case 'auc'
      opts.errorFunction = @error_auc ;
      if isempty(opts.errorLabels), opts.errorLabels = {'roc', 'prre'} ; end
    case 'binary'
      opts.errorFunction = @error_binary ;
      if isempty(opts.errorLabels), opts.errorLabels = {'binerr'} ; end
    otherwise
      error('Unknown error function ''%s''.', opts.errorFunction) ;
  end
end

state.getBatch = getBatch ;
stats = [] ;

% -------------------------------------------------------------------------
%                                                        Train and validate
% -------------------------------------------------------------------------

modelPath = @(ep) fullfile(opts.expDir, sprintf('net-epoch-%d.mat', ep));

start = opts.continue * findLastCheckpoint(opts.expDir) ;
if start >= 1
  fprintf('%s: resuming by loading epoch %d\n', mfilename, start) ;
  [net, stats] = loadState(modelPath(start)) ;
  % reassing previous values
  prev_objective = stats.prev_objective;
  current_objective = stats.current_objective;
  opts.learningRate = stats.learningRate;
else 
  % initialize variables to control convergence and learning rate decay
  prev_objective = 10000;
  current_objective = prev_objective/2;
  stats.converge = false;
end

epoch = start+1;


% while objective do not converge or epoch is not higher than opts.minEpochs
while ~(converge(prev_objective, current_objective, epoch, opts) || stats.converge)

  % Set the random seed based on the epoch and opts.randomSeed.
  % This is important for reproducibility, including when training
  % is restarted from a checkpoint.
  rng(epoch + opts.randomSeed) ;
  prepareGPUs(opts, epoch == start+1) ;

  % Train for one epoch.
  state.epoch = epoch ;
  % Update learning rate
  state.learningRate = opts.learningRate;
  fprintf('Learning rate = %d\n', state.learningRate);
  
  state.train = opts.train(randperm(numel(opts.train))) ; % shuffle
  state.val = opts.val(randperm(numel(opts.val))) ;
  state.imdb = imdb ;

  if numel(opts.gpus) <= 1
    [net,stats.train(epoch),prof] = process_epoch(net, state, opts, 'train') ;
    [~,stats.val(epoch)] = process_epoch(net, state, opts, 'val') ;
    if opts.profile
      profview(0,prof) ;
      keyboard ;
    end
  else
    spmd(numGpus)
      [net_, stats_.train, prof_] = process_epoch(net, state, opts, 'train') ;
      [~, stats_.val] = process_epoch(net_, state, opts, 'val') ;
      if labindex == 1, savedNet_ = net_ ; end
    end
    net = savedNet_{1} ;
    stats__ = accumulateStats(stats_) ;
    stats.train(epoch) = stats__.train ;
    stats.val(epoch) = stats__.val ;
    if opts.profile
      mpiprofile('viewer', [prof_{:,1}]) ;
      keyboard ;
    end
    clear net_ stats_ stats__ savedNet_ ;
  end

  % plot statistics
  if opts.plotStatistics
    plotStatistics(net, stats, epoch, opts);
  end
  
  % if there are enough epochs to update the objective stats
  if length(stats.train) > opts.N
      prev_objective = current_objective ;
      current_objective = mean(cell2mat({stats.train(end-opts.N+1:end).objective}));
      fprintf('Previous objective = %f -- Current objective = %f -- Improvement = %f\n', prev_objective, current_objective, (prev_objective - current_objective) / prev_objective);
      % check if learning rate has to be decreased
      if (abs(prev_objective - current_objective) / prev_objective) <  opts.decayLRThreshold
          % if that is the case, then decrease the learning rate by the given factor
          opts.learningRate = opts.learningRate * opts.lrDecayFactor;
      end
  end
  
  % save the model
  if ~evaluateMode
    saveState(modelPath(epoch), net, stats) ;
  end
  
  stats.learningRate = opts.learningRate;
  stats.prev_objective = prev_objective;
  stats.current_objective = current_objective;
  
  % increment epoch
  epoch = epoch + 1;
  
end
stats.converge = true;
fprintf('%d\n',stats.train(end).objective);
fprintf('%d\n',stats.train(end).prre);
fprintf('%d\n',stats.train(end).roc);
fprintf('%d\n',stats.val(end).objective);
fprintf('%d\n',stats.val(end).prre);
fprintf('%d\n',stats.val(end).roc);

% -------------------------------------------------------------------------
function plotStatistics(net, stats, epoch, opts)
% -------------------------------------------------------------------------
    modelFigPath = fullfile(opts.expDir, 'net-train.pdf') ;
    modelFigPathFig = fullfile(opts.expDir, 'net-train.fig') ;    
    switchFigure(1) ; clf ;
    plots = setdiff(...
      cat(2,...
      fieldnames(stats.train)', ...
      fieldnames(stats.val)'), {'num', 'time', 'objective'}) ;
    plots = cat(2, {'objective'}, plots);
    for p = plots
      p = char(p) ;
      values = zeros(0, epoch) ;
      leg = {} ;
      for f = {'train', 'val'}
        f = char(f) ;
        if isfield(stats.(f), p)
          tmp = [stats.(f).(p)] ;
          values(end+1,:) = tmp(1,:)' ;
          leg{end+1} = f ;
        end
      end
      subplot(1,numel(plots),find(strcmp(p,plots))) ;
      plot(1:epoch, values','LineStyle','-', 'LineWidth',1) ;
      xlabel('epoch') ;

      % depending on the problem, plot using different limits
      if length(net.meta.classes.name) > 2

          if strcmp(p, 'objective')
            ylim([0 2]);
          else
            ylim([0 0.6]); 
          end

      else

          if ~strcmp(p, 'objective')
            if strcmp(opts.errorFunction_string, 'auc')
                ylim([0 1]);
            elseif strcmp(opts.errorFunction_string, 'multiclass')
                ylim([0 0.3]);
            end
          end

      end    
      if (epoch<2)
        xlim([1 2]);
      else
        xlim([1 epoch]);
      end
      title(p) ;
      legend(leg{:}, 'location', 'best') ;
      grid on ;
    end
    drawnow ;
    print(1, modelFigPath, '-dpdf') ;
    savefig(modelFigPathFig);

% -------------------------------------------------------------------------
function err = error_multiclass(params, labels, res)
% -------------------------------------------------------------------------
predictions = gather(res(end-1).x) ;
[~,predictions] = sort(predictions, 3, 'descend') ;

% be resilient to badly formatted labels
if numel(labels) == size(predictions, 4)
  labels = reshape(labels,1,1,1,[]) ;
end

% skip null labels
mass = single(labels(:,:,1,:) > 0) ;
if size(labels,3) == 2
  % if there is a second channel in labels, used it as weights
  mass = mass .* labels(:,:,2,:) ;
  labels(:,:,2,:) = [] ;
end

m = min(5, size(predictions,3)) ;

error = ~bsxfun(@eq, predictions, labels) ;
err(1,1) = sum(sum(sum(mass .* error(:,:,1,:)))) ;
%err(2,1) = sum(sum(sum(mass .* min(error(:,:,1:m,:),[],3)))) ;



% -------------------------------------------------------------------------
function err = error_auc(opts, labels, res)
% -------------------------------------------------------------------------
predictions = squeeze(gather(res(end-1).x))';
if (size(predictions, 2) > size(predictions, 1))
    predictions = predictions';
end
if (size(predictions, 2) > 1)
    predictions = predictions(:,2);
end

% be resilient to badly formatted labels
if numel(labels) == size(predictions, 4)
  labels = reshape(labels,1,1,1,[]) ;
end
labels = squeeze(labels);
if (size(labels, 2) > size(labels, 1))
    labels = labels';
end

labels = labels - min(labels);

[~,~, info] = vl_roc( 2*labels-1, predictions );
err(1,1) = info.auc;
[~,~, info] = vl_pr( 2*labels-1, predictions );
err(1,2) = info.auc;



% -------------------------------------------------------------------------
function  [net_cpu,stats,prof] = process_epoch(net, state, opts, mode)
% -------------------------------------------------------------------------

    % initialize empty momentum
    if strcmp(mode,'train')
      state.momentum = {} ;
      for i = 1:numel(net.layers)
        if isfield(net.layers{i}, 'weights')
          for j = 1:numel(net.layers{i}.weights)
            state.layers{i}.momentum{j} = 0 ;
          end
        end
      end
    end

    % move CNN  to GPU as needed
    numGpus = numel(opts.gpus) ;
    if numGpus >= 1
      net = vl_simplenn_move(net, 'gpu') ;
    end
    if numGpus > 1
      mmap = map_gradients(opts.memoryMapFile, net, numGpus) ;
    else
      mmap = [] ;
    end

    % profile
    if opts.profile
      if numGpus <= 1
        profile clear ;
        profile on ;
      else
        mpiprofile reset ;
        mpiprofile on ;
      end
    end

    subset = state.(mode) ;
    if strcmp(opts.errorFunction_string, 'auc')
        num = [0; 0; 0] ;
    else
        num = [0; 0] ;
    end
    stats.num = 0 ; % return something even if subset = []
    stats.time = 0 ;
    adjustTime = 0 ;
    res = [] ;
    error = [] ;

    start = tic ;
    for t=1:opts.batchSize:numel(subset)
      fprintf('%s: epoch %02d: %3d/%3d:', mode, state.epoch, ...
              fix((t-1)/opts.batchSize)+1, ceil(numel(subset)/opts.batchSize)) ;
      batchSize = min(opts.batchSize, numel(subset) - t + 1) ;

      for s=1:opts.numSubBatches
        % get this image batch and prefetch the next
        batchStart = t + (labindex-1) + (s-1) * numlabs ;
        batchEnd = min(t+opts.batchSize-1, numel(subset)) ;
        batch = subset(batchStart : opts.numSubBatches * numlabs : batchEnd) ;
        
        % depending on the error function, we will divide by the total
        % amount of samples or by the number of batches
        if strcmp(opts.errorFunction_string, 'auc')
            num = [num(1) + numel(batch); num(2) + 1; num(3) + 1]  ;
        else
            num = [num(1) + numel(batch); num(2) + numel(batch)]  ;
        end
        
        if numel(batch) == 0, continue ; end

        [im, labels] = state.getBatch(state.imdb, batch) ;

        if opts.prefetch
          if s == opts.numSubBatches
            batchStart = t + (labindex-1) + opts.batchSize ;
            batchEnd = min(t+2*opts.batchSize-1, numel(subset)) ;
          else
            batchStart = batchStart + numlabs ;
          end
          nextBatch = subset(batchStart : opts.numSubBatches * numlabs : batchEnd) ;
          state.getBatch(state.imdb, nextBatch) ;
        end

        if numGpus >= 1
          im = gpuArray(im) ;
        end

        if strcmp(mode, 'train')
          dzdy = 1 ;
          evalMode = 'normal' ;
        else
          dzdy = [] ;
          evalMode = 'test' ;
        end
        net.layers{end}.class = labels ;
        res = vl_simplenn(net, im, dzdy, res, ...
                          'accumulate', s ~= 1, ...
                          'mode', evalMode, ...
                          'conserveMemory', opts.conserveMemory, ...
                          'backPropDepth', opts.backPropDepth, ...
                          'sync', opts.sync, ...
                          'cudnn', opts.cudnn) ;

        % accumulate errors
        error = sum([error, [sum(double(gather(res(end).x))) ; % loss function 
                             reshape(opts.errorFunction(opts, labels, res),[],1) ]],2) ;
      end

      % accumulate gradient
      if strcmp(mode, 'train')
        if ~isempty(mmap)
          write_gradients(mmap, net) ;
          labBarrier() ;
        end
        [state, net] = accumulate_gradients(state, net, res, opts, batchSize, mmap) ;
      end

      % get statistics
      time = toc(start) + adjustTime ;
      batchTime = time - stats.time ;
      stats = extractStats(net, opts, error ./ num);
      stats.num = num ;
      stats.time = time ;
      currentSpeed = batchSize / batchTime ;
      averageSpeed = (t + batchSize - 1) / time ;
      if t == opts.batchSize + 1
        % compensate for the first iteration, which is an outlier
        adjustTime = 2*batchTime - time ;
        stats.time = time + adjustTime ;
      end

      %fprintf(' %.1f (%.1f) Hz', averageSpeed, currentSpeed) ;
      fprintf(' objective: %.6f', stats.objective);
      for f = setdiff(fieldnames(stats)', {'num', 'time', 'objective'})
        f = char(f) ;
        fprintf(' %s:', f) ;
        fprintf(' %.6f', stats.(f)) ;
      end
      fprintf('\n') ;

      % collect diagnostic statistics
      if strcmp(mode, 'train') && opts.plotDiagnostics
        switchfigure(2) ; clf ;
        diagn = [res.stats] ;
        diagnvar = horzcat(diagn.variation) ;
        barh(diagnvar) ;
        set(gca,'TickLabelInterpreter', 'none', ...
          'YTick', 1:numel(diagnvar), ...
          'YTickLabel',horzcat(diagn.label), ...
          'YDir', 'reverse', ...
          'XScale', 'log', ...
          'XLim', [1e-5 1]) ;
        drawnow ;
      end
    end

    if ~isempty(mmap)
      unmap_gradients(mmap) ;
    end

    if opts.profile
      if numGpus <= 1
        prof = profile('info') ;
        profile off ;
      else
        prof = mpiprofile('info');
        mpiprofile off ;
      end
    else
      prof = [] ;
    end

    net_cpu = vl_simplenn_move(net, 'cpu') ;

% -------------------------------------------------------------------------
function [state, net] = accumulate_gradients(state, net, res, opts, batchSize, mmap)
% -------------------------------------------------------------------------
    numGpus = numel(opts.gpus) ;
    otherGpus = setdiff(1:numGpus, labindex) ;

    for l=numel(net.layers):-1:1
      for j=1:numel(res(l).dzdw)

        % accumualte gradients from multiple labs (GPUs) if needed
        if numGpus > 1
          tag = sprintf('l%d_%d',l,j) ;
          for g = otherGpus
            tmp = gpuArray(mmap.Data(g).(tag)) ;
            res(l).dzdw{j} = res(l).dzdw{j} + tmp ;
          end
        end

        if j == 3 && strcmp(net.layers{l}.type, 'bnorm')
          % special case for learning bnorm moments
          thisLR = net.layers{l}.learningRate(j) ;
          net.layers{l}.weights{j} = ...
            (1 - thisLR) * net.layers{l}.weights{j} + ...
            (thisLR/batchSize) * res(l).dzdw{j} ;
        else
          % standard gradient training
          thisDecay = opts.weightDecay * net.layers{l}.weightDecay(j) ;
          thisLR = state.learningRate * net.layers{l}.learningRate(j) ;
          state.layers{l}.momentum{j} = opts.momentum * state.layers{l}.momentum{j} ...
            - thisDecay * net.layers{l}.weights{j} ...
            - (1 / batchSize) * res(l).dzdw{j} ;
          net.layers{l}.weights{j} = net.layers{l}.weights{j} + ...
            thisLR * state.layers{l}.momentum{j} ;
        end

        % if requested, collect some useful stats for debugging
        if opts.plotDiagnostics
          variation = [] ;
          label = '' ;
          switch net.layers{l}.type
            case {'conv','convt'}
              variation = thisLR * mean(abs(state.layers{l}.momentum{j}(:))) ;
              if j == 1 % fiters
                base = mean(abs(net.layers{l}.weights{j}(:))) ;
                label = 'filters' ;
              else % biases
                base = mean(abs(res(l+1).x(:))) ;
                label = 'biases' ;
              end
              variation = variation / base ;
              label = sprintf('%s_%s', net.layers{l}.name, label) ;
          end
          res(l).stats.variation(j) = variation ;
          res(l).stats.label{j} = label ;
        end
      end
    end

% -------------------------------------------------------------------------
function mmap = map_gradients(fname, net, numGpus)
% -------------------------------------------------------------------------
    format = {} ;
    for i=1:numel(net.layers)
      for j=1:numel(net.layers(i).params)
        par = net.layers(i).params{j} ;
        format(end+1,1:3) = {'single', size(par), sprintf('l%d_%d',i,j)} ;
      end
    end
    format(end+1,1:3) = {'double', [3 1], 'errors'} ;
    if ~exist(fname) && (labindex == 1)
      f = fopen(fname,'wb') ;
      for g=1:numGpus
        for i=1:size(format,1)
          fwrite(f,zeros(format{i,2},format{i,1}),format{i,1}) ;
        end
      end
      fclose(f) ;
    end
    labBarrier() ;
    mmap = memmapfile(fname, ...
                      'Format', format, ...
                      'Repeat', numGpus, ...
                      'Writable', true) ;

% -------------------------------------------------------------------------
function write_gradients(mmap, net, res)
% -------------------------------------------------------------------------
for i=1:numel(net.layers)
  for j=1:numel(res(i).dzdw)
    mmap.Data(labindex).(sprintf('l%d_%d',i,j)) = gather(res(i).dzdw{j}) ;
  end
end

% -------------------------------------------------------------------------
function unmap_gradients(mmap)
% -------------------------------------------------------------------------

% -------------------------------------------------------------------------
function stats = accumulateStats(stats_)
% -------------------------------------------------------------------------
for s = {'train', 'val'}
  s = char(s) ;
  total = 0 ;

  % initialize stats stucture with same fields and same order as
  % stats_{1}
  stats__ = stats_{1} ;
  names = fieldnames(stats__.(s))' ;
  values = zeros(1, numel(names)) ;
  fields = cat(1, names, num2cell(values)) ;
  stats.(s) = struct(fields{:}) ;

  for g = 1:numel(stats_)
    stats__ = stats_{g} ;
    num__ = stats__.(s).num ;
    total = total + num__ ;

    for f = setdiff(fieldnames(stats__.(s))', 'num')
      f = char(f) ;
      stats.(s).(f) = stats.(s).(f) + stats__.(s).(f) * num__ ;

      if g == numel(stats_)
        stats.(s).(f) = stats.(s).(f) / total ;
      end
    end
  end
  stats.(s).num = total ;
end

% -------------------------------------------------------------------------
function stats = extractStats(net, opts, errors)
% -------------------------------------------------------------------------
stats.objective = errors(1) ;
for i = 1:numel(opts.errorLabels)
  stats.(opts.errorLabels{i}) = errors(i+1) ;
end

% -------------------------------------------------------------------------
function saveState(fileName, net, stats)
% -------------------------------------------------------------------------
save(fileName, 'net', 'stats') ;

% -------------------------------------------------------------------------
function [net, stats] = loadState(fileName)
% -------------------------------------------------------------------------
load(fileName, 'net', 'stats') ;
net = vl_simplenn_tidy(net) ;

% -------------------------------------------------------------------------
function epoch = findLastCheckpoint(modelDir)
% -------------------------------------------------------------------------
list = dir(fullfile(modelDir, 'net-epoch-*.mat')) ;
tokens = regexp({list.name}, 'net-epoch-([\d]+).mat', 'tokens') ;
epoch = cellfun(@(x) sscanf(x{1}{1}, '%d'), tokens) ;
epoch = max([epoch 0]) ;

% -------------------------------------------------------------------------
function switchFigure(n)
% -------------------------------------------------------------------------
if get(0,'CurrentFigure') ~= n
  try
    set(0,'CurrentFigure',n) ;
  catch
    figure(n) ;
  end
end

% -------------------------------------------------------------------------
function prepareGPUs(opts, cold)
% -------------------------------------------------------------------------
numGpus = numel(opts.gpus) ;
if numGpus > 1
  % check parallel pool integrity as it could have timed out
  pool = gcp('nocreate') ;
  if ~isempty(pool) && pool.NumWorkers ~= numGpus
    delete(pool) ;
  end
  pool = gcp('nocreate') ;
  if isempty(pool)
    parpool('local', numGpus) ;
    cold = true ;
  end
  if exist(opts.memoryMapFile)
    delete(opts.memoryMapFile) ;
  end
end
if numGpus >= 1 && cold
  fprintf('%s: resetting GPU\n', mfilename)
  if numGpus == 1
    gpuDevice(opts.gpus)
  else
    spmd, gpuDevice(opts.gpus(labindex)), end
  end
end

% -------------------------------------------------------------------------
function is_converging = converge(prev_objective, current_objective, epoch, opts)
% -------------------------------------------------------------------------
is_converging = ...
    (((abs(prev_objective - current_objective) / prev_objective) < opts.convergenceThreshold) && ... % diference with respect to last objective must be smaller than a threshold and...
    (epoch > opts.minEpochs)) ... % current epoch must be higher than the minimum
    || ...
    (epoch > opts.maxEpochs); % but we can always converge if we have reached the maximum
    
