require('nngraph')

--[[
Implementation of a single stacked-LSTM step as
an nn unit.

      h^L_{t-1} --- h^L_t
      c^L_{t-1} --- c^L_t
                 |


                 .
                 |
             [dropout]
                 |
      h^1_{t-1} --- h^1_t
      c^1_{t-1} --- c^1_t
                 |
                 |
                x_t

Computes $$(c_{t-1}, h_{t-1}, x_t) => (c_{t}, h_{t})$$.

--]]
local CPLSTM, parent = torch.class('onmt.CPLSTM', 'onmt.Network')

--[[
Parameters:

  * `layers` - Number of LSTM layers, L.
  * `inputSize` - Size of input layer
  * `hiddenSize` - Size of the hidden layers.
  * `dropout` - Dropout rate to use.
  * `residual` - Residual connections between layers.
--]]
function CPLSTM:__init(layers, inputSize, hiddenSize, dropout, residual)
  dropout = dropout or 0

  self.dropout = dropout
  self.numEffectiveLayers = 2 * layers
  self.outputSize = hiddenSize

  parent.__init(self, self:_buildModel(layers, inputSize, hiddenSize, dropout, residual))
end

function CPLSTM:setRepeats(batchSize, nInputs)
    self.inpRep.nfeatures = batchSize
    self.hidRep.nfeatures = nInputs
    self.cellRep.nfeatures = nInputs
    self.forgetViewer:resetSize(batchSize, -1, self.outputSize)
end

function CPLSTM:shareParams(net)
    local myfound = 0
    local myi2h, myh2h
    -- first find our own linears
    self.net:apply(function(mod)
                        if mod.name then
                            if mod.name == "i2h" then
                                myi2h = mod
                                myfound = myfound + 1
                            elseif mod.name == "h2h" then
                                myh2h = mod
                                myfound = myfound + 1
                            end
                        end
                    end)
    assert(myfound == 2)

    local otherfound = 0
    local otheri2h, otherh2h
    net:apply(function(mod)
                        if mod.name then
                            if mod.name == "i2h" then
                                otheri2h = mod
                                otherfound = otherfound + 1
                            elseif mod.name == "h2h" then
                                otherh2h = mod
                                otherfound = otherfound + 1
                            end
                        end
                    end)
    assert(otherfound == 2)
    myi2h:share(otheri2h, 'weight', 'bias')
    myh2h:share(otherh2h, 'weight', 'bias')
end

--[[ Stack the LSTM units. ]]
function CPLSTM:_buildModel(layers, inputSize, hiddenSize, dropout, residual)
  local inputs = {}
  local outputs = {}

  for _ = 1, layers do
    table.insert(inputs, nn.Identity()()) -- c0: batchSize x hiddenSize
    table.insert(inputs, nn.Identity()()) -- h0: batchSize x hiddenSize
  end

  table.insert(inputs, nn.Identity()()) -- x: batchSize x inputSize
  local x = inputs[#inputs]

  local prevInput
  local nextC
  local nextH

  for L = 1, layers do
    local input
    local inputDim

    if L == 1 then
      -- First layer input is x.
      input = x
      inputDim = inputSize
    else
      inputDim = hiddenSize
      input = nextH
      if residual and (L > 2 or inputSize == hiddenSize) then
        input = nn.CAddTable()({input, prevInput})
      end
      if dropout > 0 then
        input = nn.Dropout(dropout)(input)
      end
    end

    local prevC = inputs[L*2 - 1]
    local prevH = inputs[L*2]

    nextC, nextH = self:_buildLayer(inputDim, hiddenSize)({prevC, prevH, input}):split(2)
    prevInput = input

    table.insert(outputs, nextC)
    table.insert(outputs, nextH)
  end

  return nn.gModule(inputs, outputs)
end

--[[ Build a single LSTM unit layer. ]]
function CPLSTM:_buildLayer(inputSize, hiddenSize)
  local inputs = {}
  table.insert(inputs, nn.Identity()())
  table.insert(inputs, nn.Identity()())
  table.insert(inputs, nn.Identity()())

  local prevC = inputs[1]
  local prevH = inputs[2]
  local x = inputs[3]

  -- Evaluate the input sums at once for efficiency.
  --local i2h = nn.Linear(inputSize, 4 * hiddenSize)(x)
  local i2hlin = nn.Linear(inputSize, 4 * hiddenSize)
  -- for forget init shit
  i2hlin.name = "i2h"
  i2hlin.postParametersInitialization = function()
      -- forget gate is second thing in this big Linear
      print("setting forget gate bias to 2")
      i2hlin.bias:sub(hiddenSize+1, 2*hiddenSize):fill(2)
  end
  local i2h = i2hlin(x)

  local h2hlin = nn.Linear(hiddenSize, 4 * hiddenSize, false)
  h2hlin.name = "h2h"
  local h2h = h2hlin(prevH)

  local defaultBatchSize, defaultNInpts = 32, 10 -- doesn't matter
  self.inpRep = nn.Replicate(defaultBatchSize, 1, 2)
  self.hidRep = nn.Replicate(defaultNInpts, 2, 2)
  local exi2h = self.inpRep(i2h) -- batchSize x nInputs x 4*dim
  local exh2h = self.hidRep(h2h) -- batchsize x nInputs x 4*dim
  local sumsByBatch = nn.CAddTable()({exi2h, exh2h}) -- batchsize x nInputs x 4*dim, respecting batch order

  --local allInputSums = nn.CAddTable()({i2h, h2h})
  local allInputSums = nn.View(-1, 4*hiddenSize)(sumsByBatch) -- batchsize*nInputs x 4*dim

  local reshaped = nn.Reshape(4, hiddenSize)(allInputSums) -- batchsize*nInputs x 4 x hiddenSize
  local n1, n2, n3, n4 = nn.SplitTable(2)(reshaped):split(4) -- length-4 table w/ batchsize*nInputs x hiddenSize entries

  -- Decode the gates.
  local inGate = nn.Sigmoid()(n1)
  local forgetGate = nn.Sigmoid()(n2)
  local outGate = nn.Sigmoid()(n3)

  -- Decode the write inputs.
  local inTransform = nn.Tanh()(n4)

  self.forgetViewer = nn.View(defaultBatchSize, -1, hiddenSize)
  local forgetByBatch = self.forgetViewer(forgetGate)
  self.cellRep = nn.Replicate(defaultNInpts, 2, 2)
  local exCell = self.cellRep(prevC)


  -- Perform the LSTM update.
  local nextC = nn.CAddTable()({
    --nn.CMulTable()({forgetGate, prevC}),
    nn.View(-1, hiddenSize)(nn.CMulTable()({forgetByBatch, exCell})),
    nn.CMulTable()({inGate, inTransform})
  })

  -- Gated cells form the output.
  local nextH = nn.CMulTable()({outGate, nn.Tanh()(nextC)})

  return nn.gModule(inputs, {nextC, nextH})
end