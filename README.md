我自己的药改包配置！说不定win可以开（心虚）  

<<<<<<< HEAD
这个插件包含有本人大部分的私人设置！如服务器名、在匹配环境使用！ 需要进行修改才能使用。  
=======
**IMPORTANT NOTES** - **DON'T IGNORE THESE!**
* The goal for this repo is to work on **Linux**, but Windows support is available.
> While Windows is supported by the repository, there may be things that don't fully function on Windows that we may have missed.
> Please report any issues you run into!
* This repository only supports Sourcemod **1.11** and up.
>>>>>>> zonemodmain

虽然不太可能，但只是用来打内战的请使用这个：https://github.com/apples1949/applemod/tree/zonemodedi  

<<<<<<< HEAD
需要注意的是 我服务器的 闲置检测插件、第三人称检测插件和AI特感传送插件由于个人原因不能发这里 所以请注意第三人称插件需要恢复成zm自带的插件 对抗默认禁第三人称 理论上不用第三人称检测也没关系  

参考了很多前辈的配置 在此真心感谢！  

另外，承认用了别人的东西很难吗？
=======
This project started off with a focus on reworking the very outdated platform for competitive L4D2.
In its current state it allows anyone to host their own up to date competitive L4D2 servers.
This project is **Actively Developed**.

> **Included Matchmodes:**
* **Zonemod 2.8.8**
* **Zonemod Hunters**
* **Zonemod Retro**
* **NeoMod 0.4a** 
* **NextMod 1.0.5**
* **Promod Elite 1.1**
* **Acemod Revamped 1.2**
* **Equilibrium 3.0c**
* **Apex 1.1.2**

---

## **Important Notes**
* We've added "**mv_maxplayers**" that replaces sv_maxplayers in the Server.cfg, this is used to prevent it from being overwritten every map change.
  * On config unload, the value will be to the value used in the Server.cfg
* Every Confogl matchmode will now execute 2 additional files, namely "**sharedplugins.cfg**" and "**generalfixes.cfg**" which are located in your **left4dead2/cfg** folder.
  * "**General Fixes**" simply ensures that all the Fixes discussed in here are loaded by every Matchmode.
  * "**Shared Plugins**" is for you, the Server host. You surely have some plugins that you'd like to be loaded in every matchmode, you can define them here. 
    * **NOTE:** Plugin load locking and unlocking is no longer handled by the Configs themselves, so if you're using this project do **NOT** define plugin load locks/unlocks within the configs you're adding manually.

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
* Derpduck

> **Testing/Issue Reporting:**
* Too many to list, keep up the great work in reporting issues!

**NOTE:** If your work is being used and I forgot to credit you, my sincere apologies.  
I've done my best to include everyone on the list, simply create an issue and name the plugin/extension you've made/contributed to and I'll make sure to credit you properly.
>>>>>>> zonemodmain
