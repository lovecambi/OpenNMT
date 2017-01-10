local Memory = {}

--[[ Optimize memory usage of Neural Machine Translation.

Parameters:
  * `model` - a table containing encoder and decoder
  * `criterion` - a single target criterion object
  * `batch` - a Batch object
  * `verbose` - produce output or not

Example:

  local model = {}
  model.encoder = onmt.Models.buildEncoder(...)
  model.decoder = onmt.Models.buildDecoder(...)
  Memory.optimize(model, criterion, batch, verbose)

]]
function Memory.optimize(model, criterion, batch, verbose)
  if verbose then
    print('Preparing memory optimization...')
  end

  -- Prepare memory optimization
  local memoryOptimizer = onmt.utils.MemoryOptimizer.new({model.encoder, model.decoder})

  -- Batch of one single word since we optimize the first clone.
  local realSizes = { sourceLength = batch.sourceLength, targetLength = batch.targetLength }

  batch.sourceLength = 1
  batch.targetLength = 1

  -- Initialize all intermediate tensors with a first batch.
  local encStates, context = model.encoder:forward(batch)
  local decOutputs = model.decoder:forward(batch, encStates, context)
  decOutputs = onmt.utils.Tensor.recursiveClone(decOutputs)
  local encGradStatesOut, gradContext, _ = model.decoder:backward(batch, decOutputs, criterion)
  model.encoder:backward(batch, encGradStatesOut, gradContext)

  -- mark shared tensors
  local sharedSize, totSize = memoryOptimizer:optimize()

  if verbose then
    print(string.format(' * sharing %d%% of output/gradInput tensors memory between clones', (sharedSize / totSize)*100))
  end

  -- Restore batch to be transparent for the calling code.
  batch.sourceLength = realSizes.sourceLength
  batch.targetLength = realSizes.targetLength
end

function Memory.boxOptimize(model, nSourceRows, criterion, batch, verbose)
  if verbose then
    print('Preparing memory optimization...')
  end

  local mods = {}
  for i = 1, nSourceRows do
      table.insert(mods, model["encoder" .. i])
  end
  table.insert(mods, model.decoder)

  -- Prepare memory optimization
  local memoryOptimizer = onmt.utils.MemoryOptimizer.new(mods)

  -- Batch of one single word since we optimize the first clone.
  local realSizes = { sourceLength = batch.sourceLength, targetLength = batch.targetLength }

  batch.sourceLength = 1
  batch.targetLength = 1

  -- Initialize all intermediate tensors with a first batch.
  local allEncStates, allCtxs = {}, {}
  for j = 1, batch.sourceInput:size(1) do
      batch:setInputRow(j)
      local encStates, context = model["encoder" .. j]:forward(batch)
  end
  batch:setInputRow(nil) -- for sanity
  local decOutputs = model.decoder:forward(batch, encStates, context)
  decOutputs = onmt.utils.Tensor.recursiveClone(decOutputs)
  local encGradStatesOut, gradContext, _ = model.decoder:backward(batch, decOutputs, criterion)
  model.encoder:backward(batch, encGradStatesOut, gradContext)

  -- mark shared tensors
  local sharedSize, totSize = memoryOptimizer:optimize()

  if verbose then
    print(string.format(' * sharing %d%% of output/gradInput tensors memory between clones', (sharedSize / totSize)*100))
  end

  -- Restore batch to be transparent for the calling code.
  batch.sourceLength = realSizes.sourceLength
  batch.targetLength = realSizes.targetLength
end

return Memory
