#!/bin/bash
#SBATCH --job-name=widget2code_vllm
#SBATCH --output=sbatch_logs/screencoder_%j.out
#SBATCH --error=sbatch_logs/screencoder_%j.err
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=128G
#SBATCH --gres=gpu:4
#SBATCH --time=04:00:00
#SBATCH --account=tesi_dbilardello
#SBATCH --partition=boost_usr_prod
#SBATCH --profile=none
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user=285039@studenti.unimore.it

module unload cuda
module load cuda/12.6.3-none-none || { echo "Failed to load CUDA module"; exit 1; }

module load node-js/22.14.0-gcc-11.4.0


export KMP_DUPLICATE_LIB_OK=TRUE
export USE_TORCH=1
export USE_TF=0
export USE_PADDLE=0
export TRANSFORMERS_NO_ADVISORY_WARNINGS=1
export NCCL_P2P_DISABLE=1
export PYTORCH_ALLOC_CONF="expandable_segments:True"
export VLLM_LOGGING_LEVEL=INFO
export VLLM_NO_USAGE_STATS=1
export VLLM_TORCH_COMPILE_LEVEL=0

# ========== Cache directories ==========
export MY_CACHE_DIR="/work/tesi_dbilardello/.cache_ml"
mkdir -p "$MY_CACHE_DIR"

TRITON_LOCAL_BASE="${SLURM_TMPDIR:-/tmp}"
export TRITON_CACHE_DIR="$TRITON_LOCAL_BASE/$USER/triton_${SLURM_JOB_ID:-$$}"
mkdir -p "$TRITON_CACHE_DIR"
export HF_HOME="$MY_CACHE_DIR/huggingface"
export TORCH_HOME="$MY_CACHE_DIR/torch"
export TORCHINDUCTOR_CACHE_DIR="$MY_CACHE_DIR/torchinductor"
export XDG_CACHE_HOME="$MY_CACHE_DIR"
export PIP_CACHE_DIR="$MY_CACHE_DIR/pip"
export MPLCONFIGDIR="$MY_CACHE_DIR/matplotlib"
export PLAYWRIGHT_BROWSERS_PATH="$MY_CACHE_DIR/playwright"
export XDG_CONFIG_HOME="$MY_CACHE_DIR/config"

mkdir -p sbatch_logs

# ========== Activate venv ==========
cd apps/api
source .venv/bin/activate
npm uninstall sharp
npm install --include=optional --os=linux --cpu=x64 sharp
npx playwright install install-deps
cd ..
cd ..
npm uninstall sharp
npm install --include=optional --os=linux --cpu=x64 sharp
npx playwright install install-deps

# ========== vLLM Server (4 GPU tensor parallel) ==========
VLLM_MODEL="Qwen/Qwen3-VL-30B-A3B-Instruct"
VLLM_PORT=8000

echo "🚀 Starting vLLM server with model: $VLLM_MODEL (tp=4)..."
python -m vllm.entrypoints.openai.api_server \
    --model "$VLLM_MODEL" \
    --tensor-parallel-size 4 \
    --port "$VLLM_PORT" \
    --trust-remote-code \
    --max-model-len 30288 \
    --gpu-memory-utilization 0.75 \
    > >(tee -a sbatch_logs/vllm_server.log) 2>&1 &
VLLM_PID=$!

echo "⏳ Waiting for vLLM server (PID: $VLLM_PID)..."
for i in $(seq 1 1800); do
    if curl -sf "http://localhost:${VLLM_PORT}/health" > /dev/null 2>&1; then
        echo "✅ vLLM server ready after ${i}s!"
        break
    fi
    if ! kill -0 "$VLLM_PID" 2>/dev/null; then
        echo "❌ vLLM server process died"
        cat sbatch_logs/vllm_server.log
        exit 1
    fi
    sleep 1
done

if ! curl -sf "http://localhost:${VLLM_PORT}/health" > /dev/null 2>&1; then
    echo "❌ vLLM server failed to start within 1800s"
    echo "Last 50 lines of log:"
    tail -n 50 sbatch_logs/vllm_server.log
    kill "$VLLM_PID" 2>/dev/null
    exit 1
fi

# ========== API Server (background) ==========
echo "🚀 Starting API server..."
npm run api &
API_PID=$!

echo "⏳ Waiting for API server..."
for i in $(seq 1 600); do
    if curl -sf "http://localhost:8010/health" > /dev/null 2>&1; then
        echo "✅ API server ready after ${i}s!"
        break
    fi
    if ! kill -0 "$API_PID" 2>/dev/null; then
        echo "❌ API server process died"
        kill "$VLLM_PID" 2>/dev/null
        exit 1
    fi
    sleep 1
done

if ! curl -sf "http://localhost:8010/health" > /dev/null 2>&1; then
    echo "❌ API server failed to start within 600s"
    kill "$API_PID" "$VLLM_PID" 2>/dev/null
    exit 1
fi

# ========== Playground frontend (port 3060) ==========
FRONTEND_PORT=${FRONTEND_PORT:-3060}
export FRONTEND_PORT

echo "🚀 Starting playground frontend on port $FRONTEND_PORT..."
npm run dev -w apps/playground > >(tee -a sbatch_logs/frontend.log) 2>&1 &
FRONTEND_PID=$!

echo "⏳ Waiting for frontend on :$FRONTEND_PORT..."
for i in $(seq 1 300); do
    if curl -sf "http://localhost:${FRONTEND_PORT}/headless.html" > /dev/null 2>&1; then
        echo "✅ Frontend ready after ${i}s!"
        break
    fi
    if ! kill -0 "$FRONTEND_PID" 2>/dev/null; then
        echo "❌ Frontend process died"
        tail -n 50 sbatch_logs/frontend.log
        kill "$API_PID" "$VLLM_PID" 2>/dev/null
        exit 1
    fi
    sleep 1
done

if ! curl -sf "http://localhost:${FRONTEND_PORT}/headless.html" > /dev/null 2>&1; then
    echo "❌ Frontend failed to start within 300s"
    tail -n 50 sbatch_logs/frontend.log
    kill "$FRONTEND_PID" "$API_PID" "$VLLM_PID" 2>/dev/null
    exit 1
fi

# ========== Run pipeline ==========
echo "🏭 Starting generation pipeline..."
./scripts/generation/generate-batch.sh ./mockups ./output 1
echo "🎨 Starting rendering pipeline..."
./scripts/rendering/render-batch.sh ./output 1

# ========== Cleanup ==========
echo "🧹 Cleaning up background processes..."
kill "$FRONTEND_PID" 2>/dev/null
kill "$API_PID" 2>/dev/null
kill "$VLLM_PID" 2>/dev/null
wait "$FRONTEND_PID" 2>/dev/null
wait "$API_PID" 2>/dev/null
wait "$VLLM_PID" 2>/dev/null
echo "✅ Job completed!"