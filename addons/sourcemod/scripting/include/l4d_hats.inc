#if defined _hats_included
	#endinput
#endif
#define _hats_included



public SharedPlugin __pl_hats = 
{
	name = "l4d_hats",
	file = "l4d_hats.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_Hats_SetNTVOptional()
{
	MarkNativeAsOptional("Hats_GetHatEntity");
}
#endif



/**
 * @brief Returns the entity index of a clients hat
 *
 * @param  client			Client index.
 *
 * @return				Entity index, -1 if invalid.
 */
native int Hats_GetHatEntity(int client);



/**
 * @brief This function is called when a players hat is created.
 *
 * @param  client			Client index.
 * @param  entity			Entity index of the hat.
 * @param  sModel			Model pathname of the hat.
 *
 * @noreturn
 */
forward void Hats_OnHatCreated(int client, int entity, const char sModel[PLATFORM_MAX_PATH]);



/**
 * @brief This function is called when a players hat is removed.
 *
 * @param  client     Client index who had the model.
 * @param  entity     Entity index of the hat.
 *
 * @noreturn
 */
forward void Hats_OnHatKilled(int client, int entity);