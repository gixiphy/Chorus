#ifndef ProxyAudioDevice_h
#define ProxyAudioDevice_h

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/CoreAudio.h>
#include <vector>
#include <map>
#include <atomic>

#include "AudioDevice.h"
#include "CAMutex.h"

class AudioRingBuffer;

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Box = 2,
    kObjectID_Device = 3,
    kObjectID_Stream_Output = 4,
    kObjectID_Volume_Output_L = 5,
    kObjectID_Volume_Output_R = 6,
    kObjectID_Mute_Output_Master = 7,
    kObjectID_DataSource_Output_Master = 8
};

#define kPlugIn_BundleID "com.hermes.ChorusAudioDevice"
#define kBox_UID "ChorusAudioBox_UID"
#define kDevice_UID "ChorusAudioDevice_UID"
#define kDevice_ModelUID "ChorusAudioDevice_ModelUID"
#define kOutputDeviceDefaultBufferFrameSize 512
#define kOutputDeviceMinBufferFrameSize 4
#define kOutputDeviceDefaultActiveCondition ActiveCondition::userActive
// Default to false so the proxy device stays visible even when the target is
// unavailable. This preserves the long-standing behavior for existing users.
#define kOutputDeviceDefaultHideWhenUnavailable false

class ProxyAudioDevice {
  public:
    enum class ConfigType {
        none,
        outputDevice,
        outputDeviceBufferFrameSize,
        deviceName,
        deviceActiveCondition,
        deviceHideWhenUnavailable,
        applyVolume
    };
    enum class ActiveCondition { proxiedDeviceActive = 0, userActive = 1, always = 2 };

    ProxyAudioDevice() : inputIOIsActive(false) {};
    AudioDevice findTargetOutputAudioDevice();
    static int outputDeviceAliveListenerStatic(AudioObjectID inObjectID,
                                               UInt32 inNumberAddresses,
                                               const AudioObjectPropertyAddress *inAddresses,
                                               void *inClientData);
    int outputDeviceAliveListener(AudioObjectID inObjectID,
                                  UInt32 inNumberAddresses,
                                  const AudioObjectPropertyAddress *inAddresses);
    static int outputDeviceSampleRateListenerStatic(AudioObjectID inObjectID,
                                                    UInt32 inNumberAddresses,
                                                    const AudioObjectPropertyAddress *inAddresses,
                                                    void *inClientData);
    int outputDeviceSampleRateListener(AudioObjectID inObjectID,
                                       UInt32 inNumberAddresses,
                                       const AudioObjectPropertyAddress *inAddresses);
    void updateOutputDeviceStartedState();
    void matchOutputDeviceSampleRateNoLock();
    void matchOutputDeviceSampleRate();
    static int devicesListenerProcStatic(AudioObjectID inObjectID,
                                         UInt32 inNumberAddresses,
                                         const AudioObjectPropertyAddress *inAddresses,
                                         void *inClientData);
    int devicesListenerProc(AudioObjectID inObjectID,
                            UInt32 inNumberAddresses,
                            const AudioObjectPropertyAddress *inAddresses);
    void setupAudioDevicesListener();
    /// force：即使目標裝置的 id 沒變也整條重接。裝置消失又回來時 id 可能
    /// 一樣，而我們手上的那個已經是死的——沒有 force 就會被「沒有變動」
    /// 的捷徑擋掉，聲音再也回不來。App 明確寫入設定時一律 force。
    void setupTargetOutputDevice(bool force = false);
    void initializeOutputDevice();
    void deinitializeOutputDeviceNoLock();
    void deinitializeOutputDevice();
    void resetInputData();
    static OSStatus outputDeviceIOProcStatic(AudioDeviceID inDevice,
                                             const AudioTimeStamp *inNow,
                                             const AudioBufferList *inInputData,
                                             const AudioTimeStamp *inInputTime,
                                             AudioBufferList *outOutputData,
                                             const AudioTimeStamp *inOutputTime,
                                             void *inClientData);
    OSStatus outputDeviceIOProc(AudioDeviceID inDevice,
                                const AudioTimeStamp *inNow,
                                const AudioBufferList *inInputData,
                                const AudioTimeStamp *inInputTime,
                                AudioBufferList *outOutputData,
                                const AudioTimeStamp *inOutputTime);
    // ── 音量換算的單一來源（Chorus 擴充）───────────────────────────
    //
    // 音量有三個換算點必須互為反函數、而且與「真正乘進樣本的那個數」
    // 一致：回報 DecibelValue、ConvertScalarToDecibels／DecibelsToScalar、
    // 以及 calculateVolumeFactors。上游把它們各寫一份，於是實測（2026-08-30
    // mini）回報 −44.81 dB、實際卻套 −29.81 dB，差 15 dB——build 42 修了
    // calculateVolumeFactors 的 /10→/20，但回報路徑是「先平方再線性映射
    // 到 [−60,0]」，兩條根本是不同曲線。這兩個函式就是那唯一的來源。
    //
    // 曲線：振幅 = scalar²（平方律 taper），因此 dB = 40·log10(scalar)。
    // 滑桿 50% ＝ 振幅 25% ＝ −12 dB。舊的線性映射在 50% 是 −30 dB，
    // 逼使唯一的類比增益（螢幕 OSD）開到底，把 ring buffer 的每一個
    // 不連續一起放大 30 dB。
    Float32 volumeScalarToDecibels(Float32 scalar);
    Float32 volumeDecibelsToScalar(Float32 decibels);

    void calculateVolumeFactors(Float32 volumeL,
                                Float32 volumeR,
                                bool mute,
                                Float32 &volumeFactorL,
                                Float32 &volumeFactorR);
    bool isConfigurationString(CFStringRef val);
    void parseConfigurationString(CFStringRef configString, ConfigType &action, CFStringRef &value);
    void setConfigurationValue(ConfigType action, CFStringRef value);
    CFStringRef copyConfigurationValue(ConfigType action);
    CFStringRef copyDeviceNameFromStorage();
    void setDeviceName(CFStringRef newName);
    CFStringRef copyDefaultProxyOutputDeviceUID();
    CFStringRef copyOutputDeviceUIDFromStorage();
    void setOutputDevice(CFStringRef deviceUID);
    UInt32 retrieveOutputDeviceBufferFrameSizeFromStorage();
    void setOutputDeviceBufferFrameSize(UInt32 size);
    ActiveCondition retrieveOutputDeviceActiveConditionFromStorage();
    void setOutputDeviceActiveCondition(ActiveCondition newActiveCondition);
    bool retrieveOutputDeviceHideWhenUnavailableFromStorage();
    void setOutputDeviceHideWhenUnavailable(bool newHideWhenUnavailable);
    bool retrieveApplyVolumeFromStorage();
    void setApplyVolume(bool newApplyVolume);
    void notifyHiddenPropertyChanged();

    static ProxyAudioDevice *deviceForDriver(void *inDriver);

    //    Entry points for the COM methods
    static HRESULT ProxyAudio_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
    static ULONG ProxyAudio_AddRef(void *inDriver);
    static ULONG ProxyAudio_Release(void *inDriver);
    static OSStatus ProxyAudio_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
    static OSStatus ProxyAudio_CreateDevice(AudioServerPlugInDriverRef inDriver,
                                            CFDictionaryRef inDescription,
                                            const AudioServerPlugInClientInfo *inClientInfo,
                                            AudioObjectID *outDeviceObjectID);
    static OSStatus ProxyAudio_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
    static OSStatus ProxyAudio_AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                                               AudioObjectID inDeviceObjectID,
                                               const AudioServerPlugInClientInfo *inClientInfo);
    static OSStatus ProxyAudio_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                                  AudioObjectID inDeviceObjectID,
                                                  const AudioServerPlugInClientInfo *inClientInfo);
    static OSStatus ProxyAudio_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                                AudioObjectID inDeviceObjectID,
                                                                UInt64 inChangeAction,
                                                                void *inChangeInfo);
    static OSStatus ProxyAudio_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                              AudioObjectID inDeviceObjectID,
                                                              UInt64 inChangeAction,
                                                              void *inChangeInfo);
    static Boolean ProxyAudio_HasProperty(AudioServerPlugInDriverRef inDriver,
                                          AudioObjectID inObjectID,
                                          pid_t inClientProcessID,
                                          const AudioObjectPropertyAddress *inAddress);
    static OSStatus ProxyAudio_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                                  AudioObjectID inObjectID,
                                                  pid_t inClientProcessID,
                                                  const AudioObjectPropertyAddress *inAddress,
                                                  Boolean *outIsSettable);
    static OSStatus ProxyAudio_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                                   AudioObjectID inObjectID,
                                                   pid_t inClientProcessID,
                                                   const AudioObjectPropertyAddress *inAddress,
                                                   UInt32 inQualifierDataSize,
                                                   const void *inQualifierData,
                                                   UInt32 *outDataSize);
    static OSStatus ProxyAudio_GetPropertyData(AudioServerPlugInDriverRef inDriver,
                                               AudioObjectID inObjectID,
                                               pid_t inClientProcessID,
                                               const AudioObjectPropertyAddress *inAddress,
                                               UInt32 inQualifierDataSize,
                                               const void *inQualifierData,
                                               UInt32 inDataSize,
                                               UInt32 *outDataSize,
                                               void *outData);
    static OSStatus ProxyAudio_SetPropertyData(AudioServerPlugInDriverRef inDriver,
                                               AudioObjectID inObjectID,
                                               pid_t inClientProcessID,
                                               const AudioObjectPropertyAddress *inAddress,
                                               UInt32 inQualifierDataSize,
                                               const void *inQualifierData,
                                               UInt32 inDataSize,
                                               const void *inData);
    static OSStatus ProxyAudio_StartIO(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inDeviceObjectID,
                                       UInt32 inClientID);
    static OSStatus ProxyAudio_StopIO(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inDeviceObjectID,
                                      UInt32 inClientID);
    static OSStatus ProxyAudio_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                                AudioObjectID inDeviceObjectID,
                                                UInt32 inClientID,
                                                Float64 *outSampleTime,
                                                UInt64 *outHostTime,
                                                UInt64 *outSeed);
    static OSStatus ProxyAudio_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                                 AudioObjectID inDeviceObjectID,
                                                 UInt32 inClientID,
                                                 UInt32 inOperationID,
                                                 Boolean *outWillDo,
                                                 Boolean *outWillDoInPlace);
    static OSStatus ProxyAudio_BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                                                AudioObjectID inDeviceObjectID,
                                                UInt32 inClientID,
                                                UInt32 inOperationID,
                                                UInt32 inIOBufferFrameSize,
                                                const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
    static OSStatus ProxyAudio_DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                             AudioObjectID inDeviceObjectID,
                                             AudioObjectID inStreamObjectID,
                                             UInt32 inClientID,
                                             UInt32 inOperationID,
                                             UInt32 inIOBufferFrameSize,
                                             const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
                                             void *ioMainBuffer,
                                             void *ioSecondaryBuffer);
    static OSStatus ProxyAudio_EndIOOperation(AudioServerPlugInDriverRef inDriver,
                                              AudioObjectID inDeviceObjectID,
                                              UInt32 inClientID,
                                              UInt32 inOperationID,
                                              UInt32 inIOBufferFrameSize,
                                              const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

    //    Implementation
    HRESULT QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
    ULONG AddRef(void *inDriver);
    ULONG Release(void *inDriver);
    OSStatus Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
    OSStatus CreateDevice(AudioServerPlugInDriverRef inDriver,
                          CFDictionaryRef inDescription,
                          const AudioServerPlugInClientInfo *inClientInfo,
                          AudioObjectID *outDeviceObjectID);
    OSStatus DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
    OSStatus AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                             AudioObjectID inDeviceObjectID,
                             const AudioServerPlugInClientInfo *inClientInfo);
    OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                AudioObjectID inDeviceObjectID,
                                const AudioServerPlugInClientInfo *inClientInfo);
    OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                              AudioObjectID inDeviceObjectID,
                                              UInt64 inChangeAction,
                                              void *inChangeInfo);
    OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                            AudioObjectID inDeviceObjectID,
                                            UInt64 inChangeAction,
                                            void *inChangeInfo);
    Boolean HasProperty(AudioServerPlugInDriverRef inDriver,
                        AudioObjectID inObjectID,
                        pid_t inClientProcessID,
                        const AudioObjectPropertyAddress *inAddress);
    OSStatus IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                AudioObjectID inObjectID,
                                pid_t inClientProcessID,
                                const AudioObjectPropertyAddress *inAddress,
                                Boolean *outIsSettable);
    OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                 AudioObjectID inObjectID,
                                 pid_t inClientProcessID,
                                 const AudioObjectPropertyAddress *inAddress,
                                 UInt32 inQualifierDataSize,
                                 const void *inQualifierData,
                                 UInt32 *outDataSize);
    OSStatus GetPropertyData(AudioServerPlugInDriverRef inDriver,
                             AudioObjectID inObjectID,
                             pid_t inClientProcessID,
                             const AudioObjectPropertyAddress *inAddress,
                             UInt32 inQualifierDataSize,
                             const void *inQualifierData,
                             UInt32 inDataSize,
                             UInt32 *outDataSize,
                             void *outData);
    OSStatus SetPropertyData(AudioServerPlugInDriverRef inDriver,
                             AudioObjectID inObjectID,
                             pid_t inClientProcessID,
                             const AudioObjectPropertyAddress *inAddress,
                             UInt32 inQualifierDataSize,
                             const void *inQualifierData,
                             UInt32 inDataSize,
                             const void *inData);
    OSStatus StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
    OSStatus StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
    OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                              AudioObjectID inDeviceObjectID,
                              UInt32 inClientID,
                              Float64 *outSampleTime,
                              UInt64 *outHostTime,
                              UInt64 *outSeed);
    OSStatus WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                               AudioObjectID inDeviceObjectID,
                               UInt32 inClientID,
                               UInt32 inOperationID,
                               Boolean *outWillDo,
                               Boolean *outWillDoInPlace);
    OSStatus BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                              AudioObjectID inDeviceObjectID,
                              UInt32 inClientID,
                              UInt32 inOperationID,
                              UInt32 inIOBufferFrameSize,
                              const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
    OSStatus DoIOOperation(AudioServerPlugInDriverRef inDriver,
                           AudioObjectID inDeviceObjectID,
                           AudioObjectID inStreamObjectID,
                           UInt32 inClientID,
                           UInt32 inOperationID,
                           UInt32 inIOBufferFrameSize,
                           const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
                           void *ioMainBuffer,
                           void *ioSecondaryBuffer);
    OSStatus EndIOOperation(AudioServerPlugInDriverRef inDriver,
                            AudioObjectID inDeviceObjectID,
                            UInt32 inClientID,
                            UInt32 inOperationID,
                            UInt32 inIOBufferFrameSize,
                            const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

    Boolean HasPlugInProperty(AudioServerPlugInDriverRef inDriver,
                              AudioObjectID inObjectID,
                              pid_t inClientProcessID,
                              const AudioObjectPropertyAddress *inAddress);
    OSStatus IsPlugInPropertySettable(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inObjectID,
                                      pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress *inAddress,
                                      Boolean *outIsSettable);
    OSStatus GetPlugInPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inObjectID,
                                       pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress *inAddress,
                                       UInt32 inQualifierDataSize,
                                       const void *inQualifierData,
                                       UInt32 *outDataSize);
    OSStatus GetPlugInPropertyData(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inObjectID,
                                   pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress *inAddress,
                                   UInt32 inQualifierDataSize,
                                   const void *inQualifierData,
                                   UInt32 inDataSize,
                                   UInt32 *outDataSize,
                                   void *outData);
    OSStatus SetPlugInPropertyData(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inObjectID,
                                   pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress *inAddress,
                                   UInt32 inQualifierDataSize,
                                   const void *inQualifierData,
                                   UInt32 inDataSize,
                                   const void *inData,
                                   UInt32 *outNumberPropertiesChanged,
                                   AudioObjectPropertyAddress outChangedAddresses[2]);
    Boolean HasBoxProperty(AudioServerPlugInDriverRef inDriver,
                           AudioObjectID inObjectID,
                           pid_t inClientProcessID,
                           const AudioObjectPropertyAddress *inAddress);
    OSStatus IsBoxPropertySettable(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inObjectID,
                                   pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress *inAddress,
                                   Boolean *outIsSettable);
    OSStatus GetBoxPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inObjectID,
                                    pid_t inClientProcessID,
                                    const AudioObjectPropertyAddress *inAddress,
                                    UInt32 inQualifierDataSize,
                                    const void *inQualifierData,
                                    UInt32 *outDataSize);
    OSStatus GetBoxPropertyData(AudioServerPlugInDriverRef inDriver,
                                AudioObjectID inObjectID,
                                pid_t inClientProcessID,
                                const AudioObjectPropertyAddress *inAddress,
                                UInt32 inQualifierDataSize,
                                const void *inQualifierData,
                                UInt32 inDataSize,
                                UInt32 *outDataSize,
                                void *outData);
    OSStatus SetBoxPropertyData(AudioServerPlugInDriverRef inDriver,
                                AudioObjectID inObjectID,
                                pid_t inClientProcessID,
                                const AudioObjectPropertyAddress *inAddress,
                                UInt32 inQualifierDataSize,
                                const void *inQualifierData,
                                UInt32 inDataSize,
                                const void *inData,
                                UInt32 *outNumberPropertiesChanged,
                                AudioObjectPropertyAddress outChangedAddresses[2]);

    Boolean HasDeviceProperty(AudioServerPlugInDriverRef inDriver,
                              AudioObjectID inObjectID,
                              pid_t inClientProcessID,
                              const AudioObjectPropertyAddress *inAddress);
    OSStatus IsDevicePropertySettable(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inObjectID,
                                      pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress *inAddress,
                                      Boolean *outIsSettable);
    OSStatus GetDevicePropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inObjectID,
                                       pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress *inAddress,
                                       UInt32 inQualifierDataSize,
                                       const void *inQualifierData,
                                       UInt32 *outDataSize);
    OSStatus GetDevicePropertyData(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inObjectID,
                                   pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress *inAddress,
                                   UInt32 inQualifierDataSize,
                                   const void *inQualifierData,
                                   UInt32 inDataSize,
                                   UInt32 *outDataSize,
                                   void *outData);
    OSStatus SetDevicePropertyData(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inObjectID,
                                   pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress *inAddress,
                                   UInt32 inQualifierDataSize,
                                   const void *inQualifierData,
                                   UInt32 inDataSize,
                                   const void *inData,
                                   UInt32 *outNumberPropertiesChanged,
                                   AudioObjectPropertyAddress outChangedAddresses[2]);
    Boolean HasStreamProperty(AudioServerPlugInDriverRef inDriver,
                              AudioObjectID inObjectID,
                              pid_t inClientProcessID,
                              const AudioObjectPropertyAddress *inAddress);
    OSStatus IsStreamPropertySettable(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inObjectID,
                                      pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress *inAddress,
                                      Boolean *outIsSettable);
    OSStatus GetStreamPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inObjectID,
                                       pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress *inAddress,
                                       UInt32 inQualifierDataSize,
                                       const void *inQualifierData,
                                       UInt32 *outDataSize);
    OSStatus GetStreamPropertyData(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inObjectID,
                                   pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress *inAddress,
                                   UInt32 inQualifierDataSize,
                                   const void *inQualifierData,
                                   UInt32 inDataSize,
                                   UInt32 *outDataSize,
                                   void *outData);
    OSStatus SetStreamPropertyData(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inObjectID,
                                   pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress *inAddress,
                                   UInt32 inQualifierDataSize,
                                   const void *inQualifierData,
                                   UInt32 inDataSize,
                                   const void *inData,
                                   UInt32 *outNumberPropertiesChanged,
                                   AudioObjectPropertyAddress outChangedAddresses[2]);
    Boolean HasControlProperty(AudioServerPlugInDriverRef inDriver,
                               AudioObjectID inObjectID,
                               pid_t inClientProcessID,
                               const AudioObjectPropertyAddress *inAddress);
    OSStatus IsControlPropertySettable(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inObjectID,
                                       pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress *inAddress,
                                       Boolean *outIsSettable);
    OSStatus GetControlPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                        AudioObjectID inObjectID,
                                        pid_t inClientProcessID,
                                        const AudioObjectPropertyAddress *inAddress,
                                        UInt32 inQualifierDataSize,
                                        const void *inQualifierData,
                                        UInt32 *outDataSize);
    OSStatus GetControlPropertyData(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inObjectID,
                                    pid_t inClientProcessID,
                                    const AudioObjectPropertyAddress *inAddress,
                                    UInt32 inQualifierDataSize,
                                    const void *inQualifierData,
                                    UInt32 inDataSize,
                                    UInt32 *outDataSize,
                                    void *outData);
    OSStatus SetControlPropertyData(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inObjectID,
                                    pid_t inClientProcessID,
                                    const AudioObjectPropertyAddress *inAddress,
                                    UInt32 inQualifierDataSize,
                                    const void *inQualifierData,
                                    UInt32 inDataSize,
                                    const void *inData,
                                    UInt32 *outNumberPropertiesChanged,
                                    AudioObjectPropertyAddress outChangedAddresses[2]);
    void monitorUserActivity();
    void reportRealtimeDiagnostics();
    dispatch_queue_t AudioOutputDispatchQueue();
    void ExecuteInAudioOutputThread(void (^block)());
    
    CAMutex stateMutex = CAMutex("ProxyAudioStateMutex");
    CAMutex IOMutex = CAMutex("ProxyAudioIOMutex");
    CAMutex outputDeviceMutex = CAMutex("ProxyAudioOutputDeviceMutex");
    dispatch_queue_t audioOutputQueue = NULL;
    dispatch_source_t inputMonitoringTimer = NULL;
    AudioRingBuffer *inputBuffer = NULL;
    Byte *workBuffer = NULL;
    AudioDevice outputDevice;
    bool outputDeviceReady = false;
    std::atomic_bool inputIOIsActive;
    Float64 lastInputFrameTime = -1;
    Float64 lastInputBufferFrameSize = -1;
    Float64 inputOutputSampleDelta = -1;
    Float64 inputFinalFrameTime = -1;
    int inputCycleCount = 0;
    // P3（v7）：configurator 從單一全域槽改成 per-pid 槽。舊版只有一個
    // configuratorPid ＋一個 nextConfigurationToRead，兩個程序（App 與 CLI）
    // 同時走讀值協定就互相踩——後註冊的搶走 pid 槽，先前那個讀 name 拿回
    // 的是 box 名稱而不是設定值（實測踩過）。key 是 HAL 提供的 client pid
    // （不能偽造），value 是該 pid 下一次讀 box name 要回的設定。
    // stateMutex 保護；條目數實務上只有個位數（App＋CLI），註冊時設上限防呆。
    std::map<pid_t, ConfigType> configurators;
    CFStringRef deviceName = NULL;
    CFStringRef boxName = NULL;
    CFStringRef outputDeviceUID = NULL;
    UInt32 outputDeviceBufferFrameSize = kOutputDeviceDefaultBufferFrameSize;
    // Chorus 擴充：位置回授。上游只校時鐘「速率」（outputAccumulatedRateRatio），
    // 從不校讀寫頭的「位置」——掉一個 output cycle 造成的位置誤差是永久的，
    // 而且只會累加。到不了自癒，因為 inputOutputSampleDelta 算過一次之後
    // 再也不會等於 -1。這些欄位是門檻硬重同步用的。見 outputDeviceIOProc。
    UInt64 lastResyncHostTime = 0;
    // v7：resync／overrun 在 IOProc 裡只記 atomic，不再呼叫 time()/syslog()
    // ——syslog 打 syslogd 的 socket、可能阻塞，而這兩件事正好都在系統最忙
    // 的時候發生。inputMonitoringTimer（500ms）觀察計數變化後補記 log；
    // 寫入端先寫細節（relaxed）再加計數（release），觀察端 acquire 讀計數
    // 後再讀細節，保證讀到同一筆。
    std::atomic<UInt64> resyncCount{0};
    std::atomic<SInt64> lastResyncMargin{0};
    std::atomic<UInt64> overrunCount{0};
    std::atomic<Float64> lastOverrunStartFrame{0.0};
    std::atomic<SInt64> lastOverrunBufferStart{0};
    std::atomic<SInt64> lastOverrunBufferEnd{0};
    // 觀察端狀態：只在 audioOutputQueue（serial）上讀寫，不需要保護。
    UInt64 loggedResyncCount = 0;
    UInt64 loggedOverrunCount = 0;
    time_t lastOverrunLogTime = 0;
    // v8：低頻心跳的節拍計數（500ms × 1200 = 10 分鐘）。用 tick 數而不是
    // 時鐘——心跳要證明的正是「觀察端真的被排到了 1200 次」；高載下
    // dispatch timer 被 coalesce 造成的心跳遲到，本身就是有效訊號。
    UInt32 heartbeatTicks = 0;
    // P2（v6→v7）：累加器原本由 getZeroTimestampMutex 保護（IOProc 的第三把
    // 鎖）。v6 拆成兩個 atomic（sum／count）各自 exchange——但兩個 exchange
    // 不是同一個原子步驟：IOProc 的兩個 fetch_add 若剛好插在中間，sum 與
    // count 就錯配，重置後第一筆錯配時 count=1、sum=0 ⇒ rateRatio=0，時鐘
    // 一格跳零（還可能反過來觸發 drift resync）。v7 併成單一 64-bit atomic
    // 一次 exchange，錯配從此不可能發生。
    // 打包格式：低 14 bit = count（上限 10000 < 2^14），高 50 bit =
    // Σ(mRateScalar · 2^32)。mRateScalar ≈ 1.0 ⇒ 每筆 ≈ 2^32，一萬筆
    // ≈ 2^45.3，離 50 bit 的天花板還有 4 個 bit（rateScalar 到 ~16 都不會
    // 溢位）。量化誤差 2^-32 ≈ 2.3e-10，比在意的速率偏差（約 1e-5）細
    // 五個數量級。count 只由 IOProc 加、且加之前檢查上限，不會進位污染 sum。
    static constexpr Float64 kRateRatioScale = 4294967296.0; // 2^32
    static constexpr UInt64 kRateRatioCountBits = 14;
    static constexpr UInt64 kRateRatioCountMask = (1ull << kRateRatioCountBits) - 1;
    static constexpr UInt64 kRateRatioMaxSamples = 10000;
    std::atomic<UInt64> outputAccumulatedRateRatio{0};
    ActiveCondition outputDeviceActiveCondition = ActiveCondition::userActive;
    bool outputDeviceHideWhenUnavailable = kOutputDeviceDefaultHideWhenUnavailable;
    // Chorus 擴充：false = DDC 鏡射模式——IOProc 不做數位衰減（樣本原樣通過、
    // 音量由 Chorus 鏡射到螢幕的 VCP 0x62），mute 仍然有效。預設 true（數位衰減）。
    std::atomic<bool> applyVolumeToSamples{true};
    
    UInt32 gPlugIn_RefCount = 0;
    AudioServerPlugInHostRef gPlugIn_Host = NULL;
    Boolean gBox_Acquired = true;
    std::atomic<Float64> gDevice_SampleRate{44100.0};
    std::vector<Float64> gDevice_SampleRates = {22050, 44100, 48000, 88200, 96000, 176400, 192000};
    UInt64 gDevice_IOIsRunning = 0;
    const UInt32 kDevice_RingBufferSize = 16384;
    // v7：IOProc 的 resync 節流 lock-free 讀它，而取樣率切換時
    // PerformDeviceConfigurationChange 在 stateMutex 下重寫——C++ data race，
    // torn read 可讓 1 秒節流失效。比照 gDevice_SampleRate 改 atomic。
    std::atomic<Float64> gDevice_HostTicksPerFrame{0.0};
    UInt64 gDevice_NumberTimeStamps = 0;
    Float64 gDevice_AnchorSampleTime = 0.0;
    Float64 gDevice_ElapsedTicks = 0.0;
    UInt64 gDevice_AnchorHostTime = 0;
    bool gStream_Output_IsActive = true;
    // P1 修正（build 42 / driver v3）：曲線改用振幅比（/20）後，-25 的下限
    // 太淺——滑桿貼底仍有 10^(-25/20) ≈ 0.056，靜不下來。-60 是音量滑桿的
    // 常見下限（HANDOFF §7 裁決）。
    const Float32 kVolume_MinDB = -60.0;
    const Float32 kVolume_MaxDB = 0.0;
    std::atomic<Float32> gVolume_Output_L_Value{0.0};
    std::atomic<Float32> gVolume_Output_R_Value{0.0};
    std::atomic<bool> gMute_Output_Mute{false};
    const UInt32 gDevice_BytesPerFrameInChannel = 4;
    const UInt32 gDevice_ChannelsPerFrame = 2;
    const UInt32 gDevice_SafetyOffset = 0;
};

extern "C" void *ProxyAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);

#endif /* ProxyAudioDevice_h */
