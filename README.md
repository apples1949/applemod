=======  
我自己的药改包配置！  

这个插件包含有本人大量的私人设置！如服务器名、在匹配环境使用！ 需要进行修改才能使用。  
需要注意的是 我服务器的 闲置检测插件、第三人称检测插件、管道炸弹同时投抛限制和AI特感传送插件由于个人原因不能发这里 所以请注意第三人称插件需要恢复成zm自带的插件 对抗默认禁第三人称 理论上不用第三人称检测也没关系  

参考了很多前辈的配置 在此真心感谢！  

另外，承认用了别人的东西很难吗？  

社区玩家的马暂时回归  

# **L4D2 Competitive Rework**

> [!IMPORTANT]
> It is recommended to host servers on Linux, but Windows is supported.  
> When running Linux ensure that your setup is running a minimum of **`GLIBC 2.35`** (Ubuntu 22.04 or higher) or you will run into issues loading certain extensions.  
> This repository only supports Sourcemod **1.12** and up (which comes with the repository for ease of use)  

---

> [!NOTE]
> ConVar **`mv_maxplayers`** was added which replaces **`sv_maxplayers`** in **`cfg/server.cfg`**, this is used to prevent it from being overwritten every map change.  
> On config unload, the value will be reset to the value used in the **`cfg/server.cfg`**.

> [!NOTE]
> Every confogl matchmode will now execute 2 additional files; **`cfg/sharedplugins.cfg`** and **`cfg/generalfixes.cfg`**.  
> **`generalfixes.cfg`** contains all the crucial fixes that will be loaded in every matchmode.  
> **`sharedplugins.cfg`** is for you, the server owner. You can load any custom plugin that you want to be loaded in every matchmode here.

> [!CAUTION]
> Plugin load locking and unlocking is no longer handled by the configs themselves, refrain from doing it manually or you can run into issues.

## **About:**

This project started off with a focus on reworking the very outdated platform for competitive L4D2.  
In its current state it allows anyone to host their own up to date competitive L4D2 servers.

> **Included Matchmodes:**

* **Zonemod 2.9e**
* **Zonemod Hunters**
* **Zonemod Retro**
* **NeoMod 0.4a**
* **NextMod 1.0.5**
* **Promod Elite 1.1**
* **Acemod Revamped 1.2**
* **Equilibrium 3.0c**
* **Apex 1.1.2**

---

## **Credits:**

> **Foundation/Advanced Work:**

* A1m`
* AlliedModders LLC.
* "Confogl Team"
* Dr!fter
* Forgetest
* Jahze
* Lux
* Prodigysim
* Silvers
* XutaxKamay
* Visor

> **Additional Plugins/Extensions:**

* Accelerator74
* Arti
* AtomicStryker
* Backwards
* BHaType
* Blade
* Buster
* Canadarox
* CircleSquared
* Darkid
* DarkNoghri
* Dcx
* Devilesk
* Die Teetasse
* Disawar1
* Don
* Dragokas
* Dr. Gregory House
* Epilimic
* Estoopi
* Griffin
* Harry Potter
* Jacob
* Luckylock
* Madcap
* Mr. Zero
* Nielsen
* Powerlord
* Rena
* Sheo
* Sir
* Spoon
* Stabby
* Step
* Tabun
* Target
* TheTrick
* V10
* Vintik
* VoiDeD
* xoxo
* $atanic $pirit

> **Competitive Mapping Rework:**

* Aiden
* Derpduck

> [!NOTE]
> If your work is being used and I forgot to credit you, don't hesitate to contact me on Discord (user: `sirplease`)