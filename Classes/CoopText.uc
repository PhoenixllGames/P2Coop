//=============================================================================
// CoopText: the mod's menu texts in the game's language.
//
// A Russian copy of POSTAL 2 has Russian .int files but still Language=int, so the engine's own
// localization cannot tell it apart. When the stock main menu is Cyrillic, the texts come from
// P2CoopRu.int instead of the English defaults in the classes.
//=============================================================================
class CoopText extends Object
	abstract;

static function bool Russian()
{
	local string S;

	S = class'MenuMain'.default.ExitGameText;
	return S != "" && Asc(S) >= 0x400 && Asc(S) < 0x500;
}

// Replaces each of O's string properties named in Keys ("A B C") with its translation from
// section Section of P2CoopRu.int, when the game is Russian and the translation exists.
static function Translate(Object O, string Section, string Keys)
{
	local array<string> Names;
	local string S;
	local int i;

	if (!Russian())
		return;
	SplitString(Keys, " ", Names);
	for (i = 0; i < Names.Length; i++)
	{
		if (Names[i] == "")
			continue;
		S = Localize(Section, Names[i], "P2CoopRu");
		if (Left(S, 1) == "\"" && Right(S, 1) == "\"" && Len(S) >= 2)
			S = Mid(S, 1, Len(S) - 2);
		if (S != "" && Left(S, 2) != "<?")
			O.SetPropertyText(Names[i], S);
	}
}
