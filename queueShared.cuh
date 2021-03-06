//  Project Whippletree
//  http://www.icg.tugraz.at/project/parallel
//
//  Copyright (C) 2014 Institute for Computer Graphics and Vision,
//                     Graz University of Technology
//
//  Author(s):  Markus Steinberger - steinberger ( at ) icg.tugraz.at
//              Michael Kenzel - kenzel ( at ) icg.tugraz.at
//              Pedro Boechat - boechat ( at ) icg.tugraz.at
//              Bernhard Kerbl - kerbl ( at ) icg.tugraz.at
//              Mark Dokter - dokter ( at ) icg.tugraz.at
//              Dieter Schmalstieg - schmalstieg ( at ) icg.tugraz.at
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

#pragma once
#include "queueInterface.cuh"
#include "procedureInterface.cuh"
#include "procinfoTemplate.cuh"
#include "queueHelpers.cuh"
#include "random.cuh"
#include <string>

template<class PROCEDURE, int ProcId, int NumElements, bool TWarpOptimization>
struct SharedBaseQueue
{
  static const int HeaderSize = 4*sizeof(uint);

  uint procId_maxnum;
  volatile int counter;
  uint headerVersatile0;
  uint headerVerstaile1;

  typename PROCEDURE::ExpectedData queueData[NumElements];

  __inline__ __device__ void clean(int tid, int threads) 
  {
    for(int i = tid; i < 4; i+=threads)
      reinterpret_cast<uint*>(this)[i] = 0;
  }
  __inline__ __device__ void writeHeader()
  {
    procId_maxnum = (ProcId << 16) | NumElements;
  }
  __inline__ __device__ int procId() const
  {
    return procId_maxnum >> 16;
  }
  __inline__ __device__ uint numElement() const
  {
    return procId_maxnum & 0xFFFF;
  }
  __inline__ __device__ int num() const
  {
    return min(counter,NumElements);
  }
  __inline__ __device__ int count() const
  {
    return counter;
  }

  __inline__ __device__ bool enqueue(typename PROCEDURE::ExpectedData data) 
  {
    return enqueue<1>(&data);
  }

  template<uint ThreadsPerElement>
  __inline__ __device__ bool enqueue(typename PROCEDURE::ExpectedData* data) 
  {
    if(TWarpOptimization)
    {
      uint mask = __ballot(1);
      int ourcount = __popc(mask)/ThreadsPerElement;
      if(counter >= NumElements)
        return false;
      int mypos = __popc(Tools::lanemask_lt() & mask);

      int spos = -1;
      if(mypos == 0)
      {
        spos = atomicAdd((int*)&counter, ourcount);
        int canPut = max(0, min(NumElements - spos, ourcount));
        if(canPut < ourcount)
          atomicSub((int*)&counter, ourcount - canPut);
      }

      int src = __ffs(mask)-1;
      //spos = __shfl(spos, src);
      spos = warpBroadcast<32>(spos, src);

      int qpos = spos + mypos / ThreadsPerElement;
      if(qpos >= NumElements)
        return false;

      //copy TODO: for a multiple of the threadcount we can unroll that..
      for(int i = threadIdx.x % ThreadsPerElement; i < sizeof(typename PROCEDURE::ExpectedData)/sizeof(uint); i += ThreadsPerElement)
        *(reinterpret_cast<uint*>(queueData + qpos) + i) = *(reinterpret_cast<uint*>(data) + i);
      return true;
    }
    else
    {
      if(counter >= NumElements)
        return false;
      int spos = -1;
      if(threadIdx.x % ThreadsPerElement == 0)
      {
        spos = atomicAdd((int*)&counter, 1);
        if(spos >= NumElements)
          atomicSub((int*)&counter, 1);
      }
      if(ThreadsPerElement != 1)
        spos = warpBroadcast<ThreadsPerElement>(spos, 0);
        //spos = __shfl(spos, 0, ThreadsPerElement);

      if(spos >= NumElements)
        return false;

            //copy
      for(int i = threadIdx.x % ThreadsPerElement; i < sizeof(typename PROCEDURE::ExpectedData)/sizeof(uint); i += ThreadsPerElement)
        *(reinterpret_cast<uint*>(queueData) + sizeof(typename PROCEDURE::ExpectedData)/sizeof(uint)*spos + i) = *(reinterpret_cast<uint*>(data) + i);
      return true;
    }
  }

  __inline__ __device__ int dequeue(void* data, int maxnum)
  {
    int n = counter;
    __syncthreads();
    if(threadIdx.x == 0)
      counter = max(0, n - maxnum);
    int take = min(maxnum, n);
    int offset = n - take;

    for(int i = threadIdx.x; i < sizeof(typename PROCEDURE::ExpectedData)/sizeof(uint)*take; i+=blockDim.x)
     *(reinterpret_cast<uint*>(data) + i) = *(reinterpret_cast<uint*>(queueData) + sizeof(typename PROCEDURE::ExpectedData)/sizeof(uint)*offset + i);

    return take;
  }

  __inline__ __device__ int reserveRead(int maxnum, bool only_read_all = false)
  {
    int n = counter;
    if(only_read_all && n < maxnum)
      return 0;
    return max(0,min(n, maxnum));
  }
  __inline__ __device__ int startRead(typename PROCEDURE::ExpectedData*& data, int num)
  {
    int o = counter - num;
    //if(threadIdx.x == 0)
    //    printf("%d startRead %d->%d\n", blockIdx.x, o, num);
    data = queueData + o;
    return o;
  }
  __inline__ __device__ void finishRead(int id, int num)
  {
    __syncthreads();
    int c = counter;
    int additional = (c - (id + num))*sizeof(typename PROCEDURE::ExpectedData)/sizeof(uint);
    //if(threadIdx.x == 0)
    //    printf("%d finishRead %d->%d, move %d\n", blockIdx.x, c, c-num, additional);
    if(additional > 0)
    {
      //we need to copy to the front
      uint* cdata = reinterpret_cast<uint*>(queueData) + id * sizeof(typename PROCEDURE::ExpectedData)/sizeof(uint) + threadIdx.x;
      for(int i = 0; i < additional*sizeof(typename PROCEDURE::ExpectedData)/sizeof(uint); i += blockDim.x)
      {
        uint d = 0;
        if(i + threadIdx.x < additional)
          d = *(cdata + num * sizeof(typename PROCEDURE::ExpectedData)/sizeof(uint) + i);
        __syncthreads();
        if(i + threadIdx.x < additional)
          *(cdata + i) = d;
      }
    }
    __syncthreads();
    if(threadIdx.x == 0)
    {
      //int r = atomicSub((int*)&counter, num);
      counter = c - num;
    }
    __syncthreads();
  }

  static std::string name() 
  {
    return std::string("SharedBaseQueue") + (TWarpOptimization?"Warpoptimized":"");
  }
  
};

template<int Size>
struct Make16
{
  static const int Res = (Size+15)/16*16;
};

class EndSharedQueue 
{
public:
  typedef void Proc;
  template<class RootOverallNode, int MaxSize, int PrevSize = 0>
  struct Overall
  {
    static const int Size = 0;
    static const int FinalSize = 0;
    static const int FixedSize = 0;
    static const int SumSize = 0;
    static const int CountDynamicSize = 0;
  };
};


template< template<typename> class SQTraits,class Procedure>
struct GetTraitQueueSize
{
  static const int QueueSize = SQTraits<Procedure>::QueueSize;
};

//template<template<typename> class TWrapper, template<typename> class SQTraits, class Procedure>
//struct GetTraitQueueSize<SQTraits,TWrapper<Procedure> > : public GetTraitQueueSize<SQTraits,Procedure>
//{ };



//intermediate element with queue
template<class ProcInfo, int numOverall, int numPeel, template<typename> class SQTraits, int TNumElements>
class SQElementTraitsPeel
{
  public:
  typedef typename Select<ProcInfo,numPeel>::Procedure Proc;
  typedef SQElementTraitsPeel<ProcInfo,numOverall,numPeel+1,SQTraits,GetTraitQueueSize<SQTraits, typename Select<ProcInfo,numPeel+1>::Procedure >::QueueSize> NextSQElement;
  
  template<class RootOverallNode, int MaxSize, int PrevSize = 0>
  struct Overall
  {
    static const int Size = Make16<TNumElements * sizeof(typename Proc::ExpectedData) + SharedBaseQueue<Proc, 0, TNumElements, true>::HeaderSize>::Res;
    static const int NumElements = TNumElements;
    static const int SumSize = NextSQElement:: template Overall<RootOverallNode, MaxSize, PrevSize + Size>::SumSize + Size;
    static const int FixedSize = NextSQElement:: template Overall<RootOverallNode, MaxSize, PrevSize + Size>::FixedSize + Size;
    static const int CountDynamicSize = NextSQElement:: template Overall<RootOverallNode, MaxSize, PrevSize + Size>::CountDynamicSize;
  };

};


// empty element
template<class ProcInfo, int numOverall, int numPeel, template<typename> class SQTraits>
class SQElementTraitsPeel<ProcInfo,numOverall,numPeel,SQTraits,0> : public SQElementTraitsPeel<ProcInfo,numOverall,numPeel+1,SQTraits, GetTraitQueueSize<SQTraits, typename Select<ProcInfo,numPeel+1>::Procedure >::QueueSize>
{ };

// last element with no shared queue
template<class ProcInfo, int numOverall, template<typename> class SQTraits>
class SQElementTraitsPeel<ProcInfo,numOverall,numOverall,SQTraits,0> : public EndSharedQueue
{ 
public:
  typedef void Proc;
};

// last element with shared queue
template<class ProcInfo, int numOverall, template<typename> class SQTraits, int TNumElements>
class SQElementTraitsPeel<ProcInfo,numOverall,numOverall,SQTraits,TNumElements>
{ 
public:
  typedef typename Select<ProcInfo,numOverall>::Procedure Proc;
  typedef EndSharedQueue NextSQElement;
  
  template<class RootOverallNode, int MaxSize, int PrevSize = 0>
  struct Overall
  {
    static const int Size = Make16<TNumElements * sizeof(typename Proc::ExpectedData) + SharedBaseQueue<Proc, 0, TNumElements, true>::HeaderSize>::Res;
    static const int NumElements = TNumElements;
    static const int SumSize = NextSQElement:: template Overall<RootOverallNode, MaxSize, PrevSize + Size>::SumSize + Size;
    static const int FixedSize = NextSQElement:: template Overall<RootOverallNode, MaxSize, PrevSize + Size>::FixedSize + Size;
    static const int CountDynamicSize = NextSQElement:: template Overall<RootOverallNode, MaxSize, PrevSize + Size>::CountDynamicSize;
  };
};

template<class TProc, int TNum, class TNextSizeSelection = EndSharedQueue>
class SQElementFixedNum
{
public:
  typedef TProc Proc;
  typedef TNextSizeSelection NextSQElement;
  
  template<class RootOverallNode, int MaxSize, int PrevSize = 0>
  struct Overall
  {
    static const int Size = Make16<TNum * sizeof(typename TProc::ExpectedData) + SharedBaseQueue<Proc, 0, TNum, true>::HeaderSize>::Res;
    static const int NumElements = TNum;
    static const int SumSize = NextSQElement:: template Overall<RootOverallNode, MaxSize, PrevSize + Size>::SumSize + Size;
    static const int FixedSize = NextSQElement:: template Overall<RootOverallNode, MaxSize, PrevSize + Size>::FixedSize + Size;
    static const int CountDynamicSize = NextSQElement:: template Overall<RootOverallNode, MaxSize, PrevSize + Size>::CountDynamicSize;
  };
};
template<class TProc, int TSize, class TNextSizeSelection = EndSharedQueue>
class SQElementFixedSize
{
public:
  typedef TProc Proc;
  typedef TNextSizeSelection NextSQElement;
  
  template<class RootOverallNode, int MaxSize, int PrevSize = 0>
  struct Overall
  {
    static const int Size =  Make16<TSize>::Res;
    static const int NumElements = (TSize -  SharedBaseQueue<Proc, 0, 4, true>::HeaderSize) / sizeof(typename TProc::ExpectedData);
    static const int SumSize = NextSQElement:: template Overall<RootOverallNode, MaxSize, PrevSize + Size>::SumSize + Size;
    static const int FixedSize = NextSQElement:: template Overall<RootOverallNode, MaxSize, PrevSize + Size>::FixedSize + Size;
    static const int CountDynamicSize = NextSQElement:: template Overall<RootOverallNode, MaxSize, PrevSize + Size>::CountDynamicSize;
  };
};

template<class TProc, int TRemainingSizeRatio, class TNextSizeSelection = EndSharedQueue>
class SQElementDyn
{
public:
  typedef TProc Proc;
  typedef TNextSizeSelection NextSQElement;
  
  template<class RootOverallNode, int MaxSize, int PrevSize = 0>
  struct Overall
  {
    static const int CountDynamicSize = Make16<NextSQElement:: template Overall<RootOverallNode, MaxSize, PrevSize>::CountDynamicSize + TRemainingSizeRatio>::Res;
    static const int FixedSize = NextSQElement:: template Overall<RootOverallNode, MaxSize, PrevSize>::FixedSize;
    static const int Size = Make16<((MaxSize - RootOverallNode::FixedSize) / RootOverallNode::CountDynamicSize - SharedBaseQueue<Proc, 0, 4, true>::HeaderSize)/ sizeof(typename TProc::ExpectedData) * sizeof(typename TProc::ExpectedData) + SharedBaseQueue<Proc, 0, 4, true>::HeaderSize>::Res;
    static const int NumElements = (Size -  SharedBaseQueue<Proc, 0, 4, true>::HeaderSize) / sizeof(typename TProc::ExpectedData);
    static const int SumSize = NextSQElement:: template Overall<RootOverallNode, MaxSize, PrevSize + Size>::SumSize + Size;
  };
};


template<class SelectProc, class ThisProc, class BaseQ, class NextSharedQueueElement>
struct SQueueElementSelectAndForward
{
  __inline__ __device__ static bool enqueue(char* sQueueStartPointer, BaseQ* useQ, typename SelectProc::ExpectedData data)
  {
    //forward
    return NextSharedQueueElement:: template enqueue<SelectProc>(sQueueStartPointer, data);
  }
  template<int NumThreads>
  __inline__ __device__ static bool enqueue(char* sQueueStartPointer, BaseQ* useQ, typename SelectProc::ExpectedData* data)
  {
    //forward
    return NextSharedQueueElement:: template enqueue<NumThreads,SelectProc>(sQueueStartPointer, data);
  }

  __inline__ __device__ static void finishRead(char* sQueueStartPointer, BaseQ* useQ, int id, int num)
  {
    //forward
    return NextSharedQueueElement:: template finishRead <SelectProc> (sQueueStartPointer, id, num);
  }
};

template<class MatchProc, class BaseQ, class NextSharedQueueElement>
struct SQueueElementSelectAndForward<MatchProc,MatchProc,BaseQ,NextSharedQueueElement>
{
  __inline__ __device__ static bool enqueue(char* sQueueStartPointer, BaseQ* useQ, typename MatchProc::ExpectedData data)
  {
    //enqueue
    return useQ->enqueue(data);
  }
  template<int NumThreads>
  __inline__ __device__ static bool enqueue(char* sQueueStartPointer, BaseQ* useQ, typename MatchProc::ExpectedData* data)
  {
    //enqueue
    return useQ-> template enqueue<NumThreads>(data);
  }
     __inline__ __device__ static void finishRead(char* sQueueStartPointer, BaseQ* useQ,  int id, int num)
   {
      return useQ -> finishRead(id, num);
   }
};


template<template<typename> class Wrapper, class MatchProc, class BaseQ, class NextSharedQueueElement>
struct SQueueElementSelectAndForward<MatchProc,Wrapper<MatchProc>,BaseQ,NextSharedQueueElement>
{
  __inline__ __device__ static bool enqueue(char* sQueueStartPointer, BaseQ* useQ, typename MatchProc::ExpectedData data)
  {
    //enqueue
    return useQ->enqueue(data);
  }
  template<int NumThreads>
  __inline__ __device__ static bool enqueue(char* sQueueStartPointer, BaseQ* useQ, typename MatchProc::ExpectedData* data)
  {
    //enqueue
    return useQ-> template enqueue<NumThreads>(data);
  }
     __inline__ __device__ static void finishRead(char* sQueueStartPointer, BaseQ* useQ,  int id, int num)
   {
      return useQ -> finishRead(id, num);
   }
};

template<class ProcInfo, class Procedure, int MaxSize, class TSQDescription, class RootOverallNode, bool WarpOptimization, int PrevSize = 0>
class SharedQueueElement 
{
  typedef typename TSQDescription :: Proc MyProc;
  static const int Size = TSQDescription :: template Overall<RootOverallNode, MaxSize, PrevSize> :: Size;
  static const int NumElements = TSQDescription :: template Overall<RootOverallNode, MaxSize, PrevSize> :: NumElements;
  typedef SharedQueueElement<ProcInfo, typename TSQDescription::NextSQElement :: Proc, MaxSize, typename TSQDescription::NextSQElement, RootOverallNode, WarpOptimization, PrevSize + Size> NextSharedQueueElement;
  typedef SharedBaseQueue<MyProc, findProcId<ProcInfo, MyProc>::value, NumElements, WarpOptimization> MyBaseQueue;

  __inline__ __device__ 
  static MyBaseQueue* myQ(char *sQueueStartPointer) 
  {
    return reinterpret_cast<MyBaseQueue* >(sQueueStartPointer + PrevSize);
  }

public: 
  static const int requiredShared = TSQDescription :: template Overall<RootOverallNode, MaxSize, PrevSize> :: SumSize;
  
  static_assert(requiredShared <= MaxSize, "Shared Queue generated from traits is larger than specified max QueueSize");

  __inline__ __device__ static void init(char* sQueueStartPointer)
  {
    myQ(sQueueStartPointer)->clean(threadIdx.x, blockDim.x);
    myQ(sQueueStartPointer)->writeHeader();
    NextSharedQueueElement::init(sQueueStartPointer);
  }
  __inline__ __device__ static void maintain(char* sQueueStartPointer)
  { }


  template<class Procedure_>
  __inline__ __device__ static bool enqueue(char* sQueueStartPointer, typename Procedure_::ExpectedData data) 
  { 
    return SQueueElementSelectAndForward<Procedure_,MyProc,MyBaseQueue,NextSharedQueueElement> :: enqueue(sQueueStartPointer, myQ(sQueueStartPointer), data);
  }

  template<uint ThreadsPerElement, class Procedure_>
  __inline__ __device__ static bool enqueue(char* sQueueStartPointer, typename Procedure_::ExpectedData* data) 
  { 
    return SQueueElementSelectAndForward<Procedure_,MyProc,MyBaseQueue,NextSharedQueueElement> :: template enqueue<ThreadsPerElement>(sQueueStartPointer, myQ(sQueueStartPointer), data);
  }



  template<bool MultiProcedure>
  __inline__ __device__ static int dequeue(char* sQueueStartPointer, void*& data, int* procId, int maxShared = -1, int minPercent = 80)
  { 
    int maxElements = getElementCount<MyProc,MultiProcedure>();
    if(maxShared != -1)
      maxElements = min(maxElements, maxShared / ((int)sizeof(typename MyProc::ExpectedData) + MyProc::sharedMemory));

    int DequeueThreshold = minPercent*NumElements/100+1;
    int c = myQ(sQueueStartPointer)->count();
    if(c >=  min(maxElements,DequeueThreshold))
    {
      c = myQ(sQueueStartPointer)->dequeue(data, maxElements);
      if(c > 0)
      {
        *procId = MyProc::ProcedureId;
        data = ((uint*)data) + getThreadOffset<MyProc,MultiProcedure>()*sizeof(typename MyProc::ExpectedData);
      }
      return c * getThreadCount<MyProc>();
    }
    return NextSharedQueueElement :: template dequeue<MultiProcedure>(sQueueStartPointer, data, procId, maxShared, minPercent);
  }

  template<bool MultiProcedure>
  __inline__ __device__ static int dequeueSelected(char* sQueueStartPointer, void*& data, int procId, int maxNum = -1, int minPercent = 80)
  {
    int maxElements = getElementCount<MyProc>();
    if(maxNum != -1)
      maxElements = min(maxElements, maxNum);

    int DequeueThreshold = minPercent*NumElements/100+1;
    int c = myQ(sQueueStartPointer)->count();
    if(c >=  min(maxElements,DequeueThreshold))
    {
      c = myQ(sQueueStartPointer)->dequeue(data, maxElements);
      if(c > 0)
      {
        data = ((uint*)data) + getThreadOffset<MyProc>()*sizeof(typename MyProc::ExpectedData);
      }
      return c;
    }
    return NextSharedQueueElement :: template dequeueSelected<MultiProcedure>(sQueueStartPointer, data, procId, maxNum, minPercent);
  }

  template<bool MultiProcedure>
   __inline__ __device__ static int2 dequeueStartRead(char* sQueueStartPointer, void*& data, int* procId, int maxShared = -1, int minPercent = 80)
  { 
    int maxElements = getElementCount<MyProc, MultiProcedure>();
    if(maxShared != -1)
      maxElements = min(maxElements, MyProc::sharedMemory > 0 ? maxShared / (MyProc::sharedMemory) : blockDim.x);
    int c = myQ(sQueueStartPointer)->count();
    int DequeueThreshold = minPercent*NumElements/100+1;
    if(c >=  min(maxElements,DequeueThreshold))
    {
      c = myQ(sQueueStartPointer)->reserveRead(maxElements);
      int id = 0;
      if(c > 0)
      {
        typename MyProc::ExpectedData* p;
        id = myQ(sQueueStartPointer)->startRead(p, c);
        c = c * getThreadCount<MyProc>();
        data = reinterpret_cast<void*>(p + getThreadOffset<MyProc,MultiProcedure>());
        procId[0] = findProcId<ProcInfo,MyProc>::value; 
      }
      return make_int2(c, id);
    }
    return NextSharedQueueElement :: template  dequeueStartRead<MultiProcedure>(sQueueStartPointer, data, procId, maxShared, minPercent);
  }


  template<class Procedure_>
  __inline__ __device__ static void finishRead(char* sQueueStartPointer, int id, int num)
  {   
    SQueueElementSelectAndForward<Procedure_,MyProc,MyBaseQueue,NextSharedQueueElement> :: finishRead(sQueueStartPointer, myQ(sQueueStartPointer), id, num);
  }

  static std::string name()
  { 
    return std::to_string((long long)findProcId<ProcInfo,MyProc>::value) + "(" + std::to_string((long long)NumElements) + ")" + "," + NextSharedQueueElement :: name();
  }
};


// specialization for end of shared queue
template<class ProcInfo, int MaxSize,  class TSQDescription, class RootOverallNode, bool WarpOptimization, int PrevSize>
class SharedQueueElement<ProcInfo, void, MaxSize, TSQDescription,RootOverallNode,WarpOptimization,PrevSize>
{
public: 
  static const int requiredShared = 0;
  __inline__ __device__ static void init(char* sQueueStartPointer) { }
  __inline__ __device__ static void maintain(char* sQueueStartPointer) { }
  template<class Procedure>
  __inline__ __device__ static bool enqueue(char* sQueueStartPointer, typename Procedure::ExpectedData otherdata) { return false; }
  template<uint ThreadsPerElement, class Procedure>
  __inline__ __device__ static bool enqueue(char* sQueueStartPointer, typename Procedure::ExpectedData* data) { return false; }
  template<bool MultiProcedure>
  __inline__ __device__ static int dequeue(char* sQueueStartPointer, void*& data, int* procId, int maxShared = -1, int minPercent = 80) { return 0; }
  template<bool MultiProcedure>
  __inline__ __device__ static int dequeueSelected(char* sQueueStartPointer, void*& data, int procId, int maxNum = -1, int minPercent = 80) { return 0; }
  template<bool MultiProcedure>
   __inline__ __device__ static int2 dequeueStartRead(char* sQueueStartPointer, void*& data, int* procId_info, int maxShared = -1, int minPercent = 80) { return make_int2(0,0);}
  template<class Procedure>
  __inline__ __device__ static void finishRead(char* sQueueStartPointer, int id, int num) { }
  static std::string name() { return ""; }
};






//DM template<class ProcInfo, int MaxSize, class QueueDescription, bool WarpOptimization>
//DM class SharedStaticQueueDirectDefinition : public SharedQueueElement<ProcInfo, QueueDescription::Proc, MaxSize, QueueDescription, QueueDescription, WarpOptimization, 0> { };


template<class ProcInfo, int MaxSize, template<typename> class SharedQTraits, bool WarpOptimization>
class SharedStaticQueue : public SharedQueueElement<ProcInfo,
    typename SQElementTraitsPeel<ProcInfo, ProcInfo::NumProcedures-1, 0,SharedQTraits, SharedQTraits<typename Select<ProcInfo,0>::Procedure >::QueueSize>::Proc,
    MaxSize, 
    SQElementTraitsPeel<ProcInfo, ProcInfo::NumProcedures-1, 0,SharedQTraits, SharedQTraits<typename Select<ProcInfo,0>::Procedure >::QueueSize>,
    SQElementTraitsPeel<ProcInfo, ProcInfo::NumProcedures-1, 0,SharedQTraits, SharedQTraits<typename Select<ProcInfo,0>::Procedure >::QueueSize>, WarpOptimization >
{ };


template<int MaxSize, template<typename> class SharedQTraits, bool WarpOptimization>
class SharedStaticQueueTyping
{
  template<class ProcInfo>
  class Type : public SharedQueueElement<ProcInfo,
    typename SQElementTraitsPeel<ProcInfo, ProcInfo::NumProcedures-1, 0,SharedQTraits, SharedQTraits<typename Select<ProcInfo,0>::Procedure >::QueueSize>::Proc,
    MaxSize, 
    SQElementTraitsPeel<ProcInfo, ProcInfo::NumProcedures-1, 0,SharedQTraits, SharedQTraits<typename Select<ProcInfo,0>::Procedure >::QueueSize>,
    SQElementTraitsPeel<ProcInfo, ProcInfo::NumProcedures-1, 0,SharedQTraits, SharedQTraits<typename Select<ProcInfo,0>::Procedure >::QueueSize>, WarpOptimization >
  {};
};
  

template<class ProcedureInfo, template<class /*ProcedureInfo*/> class ExternalQueue, template<class /*ProcedureInfo*/> class SharedQueue, int SharedQueueFillupThreshold = 80, int GotoGlobalChance = 0>
class  SharedCombinerQueue : protected ExternalQueue<ProcedureInfo>
{
  typedef ExternalQueue<ProcedureInfo> ExtQ;
  typedef SharedQueue<ProcedureInfo> SharedQ;

public:
  static const bool needTripleCall = false;
  static const bool supportReuseInit = ExtQ::supportReuseInit;
  static const int requiredShared = ExtQ::requiredShared + SharedQ :: requiredShared;
  static const int globalMaintainMinThreads = ExtQ::globalMaintainMinThreads;
  static int globalMaintainSharedMemory(int Threads) { return ExtQ::globalMaintainSharedMemory(Threads); }
    

  __inline__ __device__ void init() 
  {
    ExtQ :: init();
  }
  
  template<class PROCEDURE>
  __inline__ __device__ bool enqueueInitial(typename PROCEDURE::ExpectedData data) 
  {
    return ExtQ :: template enqueueInitial<PROCEDURE>(data);
  }

  template<class PROCEDURE>
  __inline__ __device__ bool enqueue(typename PROCEDURE::ExpectedData data) 
  {
    extern __shared__ uint s_data[];
    if(GotoGlobalChance == 0 || whippletree::random::warp_check(100-GotoGlobalChance))
      if(SharedQ :: template enqueue<PROCEDURE>(reinterpret_cast<char*>(s_data), data))
      {
        //printf("went to shared queue\n");
        return true;
      }
    return ExtQ :: template enqueue<PROCEDURE>(data);
  }

  template<int threads, class PROCEDURE>
  __inline__ __device__ bool enqueue(typename PROCEDURE::ExpectedData* data) 
  {
    extern __shared__ uint s_data[];
    if(GotoGlobalChance == 0 || whippletree::random::warp_check(100-GotoGlobalChance))
      if(SharedQ :: template enqueue<threads, PROCEDURE>(reinterpret_cast<char*>(s_data), data))
      {
        //printf("went to shared queue\n");
        return true;
      }
    return ExtQ :: template enqueue<threads, PROCEDURE>(data);
  }

  template<bool MultiProcedure>
  __inline__ __device__ int dequeue(void*& data, int*& procId, int maxShared = -1)
  {
    extern __shared__ uint s_data[];
    int d = SharedQ :: template dequeue<MultiProcedure> (reinterpret_cast<char*>(s_data), data, procId, maxShared, SharedQueueFillupThreshold);
    if(d > 0) return d;
    d = ExtQ :: template dequeue<MultiProcedure>(data, procId, maxShared);
    if(d > 0) return d;
    return  SharedQ :: template dequeue<MultiProcedure> (reinterpret_cast<char*>(s_data), data, procId, maxShared, 0);
  }

  template<bool MultiProcedure>
  __inline__ __device__ int dequeueSelected(void*& data, int procId, int maxShared = -1)
  {
    extern __shared__ uint s_data[];
    int d = SharedQ :: dequeueSelected<MultiProcedure> (reinterpret_cast<char*>(s_data), data, procId, maxShared, SharedQueueFillupThreshold);
    if(d > 0) return d;
    d = ExtQ :: template dequeueSelected<MultiProcedure>(data, procId, maxShared);
    if(d > 0) return d;
    return SharedQ :: dequeueSelected<MultiProcedure> (reinterpret_cast<char*>(s_data), data, procId, maxShared, 0);
  }

  template<bool MultiProcedure>
  __inline__ __device__ int dequeueStartRead(void*& data, int*& procId, int maxShared = -1)
  {
    extern __shared__ uint s_data[];
    int2 d = SharedQ :: dequeueStartRead<MultiProcedure> (reinterpret_cast<char*>(s_data), data, procId, maxShared, SharedQueueFillupThreshold);
    if(d.x > 0)
    {
      procId[1] = d.y | 0x40000000;
      return d.x;
    }
    d.x = ExtQ :: template dequeueStartRead<MultiProcedure>(data, procId, maxShared);
    if(d.x > 0) 
    {
       /*  if(threadIdx.x == 0)
          printf("%d global dequeueStartRead successful %d %d\n", blockIdx.x, d.x, procId[1]);   */ 
        return d.x;
    }
    d = SharedQ :: dequeueStartRead<MultiProcedure> (reinterpret_cast<char*>(s_data), data, procId, maxShared, 0);
    if(d.x > 0)
    {
      procId[1] = d.y | 0x40000000;
      return d.x;
    }
    return 0;
  }

   template<bool MultiProcedure>
  __inline__ __device__ int dequeueStartRead1(void*& data, int*& procId, int maxShared = -1)
  {
    extern __shared__ uint s_data[];
    int2 d = SharedQ :: dequeueStartRead<MultiProcedure> (reinterpret_cast<char*>(s_data), data, procId, maxShared, SharedQueueFillupThreshold);
    procId[1] = d.y | 0x40000000;
    return d.x;
  }
  template<bool MultiProcedure>
  __inline__ __device__ int dequeueStartRead2(void*& data, int*& procId, int maxShared = -1)
  {
    extern __shared__ uint s_data[];
    return ExtQ :: template dequeueStartRead<MultiProcedure>(reinterpret_cast<char*>(s_data), data, procId, maxShared);
  }
  template<bool MultiProcedure>
  __inline__ __device__ int dequeueStartRead3(void*& data, int*& procId, int maxShared = -1)
  {
    extern __shared__ uint s_data[];
    int2 d = SharedQ :: dequeueStartRead<MultiProcedure> (reinterpret_cast<char*>(s_data), data, procId, maxShared, 0);
    procId[1] = d.y | 0x40000000;
    return d.x;
  }
  template<class PROCEDURE>
  __inline__ __device__ void finishRead1(int id,  int num)
  {
    extern __shared__ uint s_data[];
    SharedQ :: template finishRead<PROCEDURE>(reinterpret_cast<char*>(s_data), id & 0x3FFFFFFF, num);
  }
  template<class PROCEDURE>
  __inline__ __device__ void finishRead2(int id,  int num)
  {
    ExtQ :: template finishRead<PROCEDURE>(id, num);
  }
  template<class PROCEDURE>
  __inline__ __device__ void finishRead3(int id,  int num)
  {
    finishRead1<PROCEDURE>(id, num);
  }


  /*template<class PROCEDURE>
  __inline__ __device__ int reserveRead(int maxNum = -1)
  {
    return ExtQ :: template reserveRead <PROCEDURE> (data, procId, maxShared);
  }*/
  template<class PROCEDURE>
  __inline__ __device__ int startRead(void*& data, int num)
  {
    return  ExtQ :: template startRead<PROCEDURE>(data, num);
  }
  template<class PROCEDURE>
  __inline__ __device__ void finishRead(int id,  int num)
  {
    extern __shared__ uint s_data[];
    if(id & 0x40000000)
    {
      SharedQ :: template finishRead<PROCEDURE>(reinterpret_cast<char*>(s_data), id & 0x3FFFFFFF, num);
      //if(threadIdx.x == 0)
      //printf("%d shared finish read done %d %d\n", blockIdx.x, id,num);
    }
    else
    {
      ExtQ :: template finishRead<PROCEDURE>(id, num);
      // if(threadIdx.x == 0)
      //printf("%d global finish read done %d %d\n", blockIdx.x, id,num);
    }
  }

  __inline__ __device__ void numEntries(int* counts)
  {
    ExtQ :: numEntries(counts);
  }


  __inline__ __device__ void record()
  {
    ExtQ :: record();
  }
  __inline__ __device__ void reset()
  {
    ExtQ :: reset();
  }


  __inline__ __device__ void workerStart()
  { 
    extern __shared__ uint s_data[];
    SharedQ :: init(reinterpret_cast<char*>(s_data));
  }
  __inline__ __device__ void workerMaintain()
  { 
    extern __shared__ uint s_data[];
    SharedQ :: maintain(reinterpret_cast<char*>(s_data));
  }
  __inline__ __device__ void workerEnd()
  { 
    //TODO: what should we do here? enqueue shared elements to global?
  }
  __inline__ __device__ void globalMaintain()
  {
    ExtQ :: globalMaintain();
  }

  static std::string name()
  {
    if(GotoGlobalChance > 0)
      return std::string("SharedCombinedQueue_GolbalProp") + std::to_string((unsigned long long)GotoGlobalChance) + "_" + SharedQ::name() + "/" + ExtQ::name() ;
    return std::string("SharedCombinedQueue_") + SharedQ::name() + "/" + ExtQ::name() ;
  }

};

