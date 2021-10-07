﻿param
(
    $BaseDir = [Environment]::CurrentDirectory,
    $key = $env:ocp_opim_key
)


function GetCachedTranslation($cache, $text, $location, $root)
{
    if ([string]::IsNullOrEmpty($text)) 
    {
        return $text
    }

    $cacheItem = $cache | where {$_.OriginalEnglish -ceq $text}
    
    if ($cacheItem -eq $null)
    {
        return $text
    }

    #normalize path separator - win vs linux, make the path relative
    $location = $location.Replace('\', '/').Replace($root.Replace('\', '/'), "")
    if (-not $cacheItem.Locations.Contains($location))
    {
        $cacheItem.Locations += $location + [Environment]::NewLine
    }
    
    return $cacheItem.Translation
}

write-host "Starting translations in $BaseDir" 

$header = @{"Ocp-Apim-Subscription-Key"=$key; "Content-type"="Application/json; charset=UTF-8"}

$ErrorActionPreference = "Stop"

$cachePath = "$BaseDir\CustomTranslations\translationCache-cz.csv"
$enSrcLocalsPath = "$BaseDir\src\webpart\src\webparts\common\assets\locals-1033.json"
$enSrcStringsPath = "$BaseDir\src\webpart\src\webparts\common\loc\en-us.ts"


#initialize cache
if (Test-Path $cachePath)
{
    $cache = Import-Csv $cachePath -Encoding UTF8
}
else
{
    $cache = @()
}
write-host "Translations cache initialized. Number of cached translations: $($cache.Count)"


#collect texts to translate in en-us directories of the content files
$enDirs = Get-ChildItem "$BaseDir\docs" -Recurse -filter "en-us" -Directory 

$translateList = @()
foreach($enDir in $enDirs)
{
    $enDirPath = $enDir.FullName

    write-host "Collecting texts to translate from $enDirPath"
    $metadata = Get-Content "$enDirPath\metadata.json" -Encoding UTF8 | Out-String | ConvertFrom-Json
    $assets = Get-Content "$enDirPath\assets.json" -Encoding UTF8 | Out-String | ConvertFrom-Json
    $playlists = Get-Content "$enDirPath\playlists.json" -Encoding UTF8 | Out-String | ConvertFrom-Json
    
    $translateList += ($playlists.Title + 
                       $playlists.Description + 
                       $assets.Title + 
                       $assets.Description + 
                       $metadata.Technologies.Name  + 
                       $metadata.Technologies.Subjects.Name + 
                       $metadata.Categories.Name + 
                       $metadata.Categories.Subcategories.Name +
                       $metadata.Audiences.Name + 
                       $metadata.Levels.Name +
                       $metadata.StatusTag.Name ) `
                        | where{$_ -ne "" -and $cache.OriginalEnglish -notcontains $_ }  

    #add language to the manifest one folder up
    $manifest = Get-Content "$($enDir.Parent.FullName)\manifest.json" -Encoding UTF8 | Out-String | ConvertFrom-Json

    if ($manifest.Languages -notcontains "cs-CZ")
    {
        $manifest.Languages += "cs-CZ"
        $manifest | ConvertTo-Json | Set-Content "$($enDir.Parent.FullName)\manifest.json" -Encoding UTF8
    }                   
}


#collect texts in locals in the src files
write-host "Collecting texts to translate from $enSrcLocalsPath"
$locals = Get-Content $enSrcLocalsPath -Encoding UTF8 | Out-String | ConvertFrom-Json
$translateList += $locals.Description | where{$_ -ne "" -and $cache.OriginalEnglish -notcontains $_ } 

#collect texts in strings in the src files
write-host "Collecting texts to translate from $enSrcStringsPath"
$enStrings = Get-Content -LiteralPath $enSrcStringsPath -Encoding UTF8
foreach($line in $enStrings)
{
    if ($line -match "(.+): `"(.+)`"")
    {
        if ( $cache.OriginalEnglish -notcontains $matches[2] -and $translateList -notcontains $matches[2])
        {
            $translateList += $matches[2]
        }
    }
}

#translate by 100 texts chunks (max value suported by Translate service) and update the cache
$translateList = ($translateList | select -unique)
write-host "Number of texts to translate: $($translateList.Count)"


#debuging - one by one to find invalid
#foreach($t in $texts)
#{
#    $body = ConvertTo-Json @(@{"text"=$t})
#    $translate = Invoke-RestMethod "https://api.cognitive.microsofttranslator.com/translate?api-version=3.0&from=en&to=cs" -Method Post -body $body -Headers $header
#}

$maxTextsCnt = 100
$maxTextsLength = 10000
$index = 0

while ($index -lt $translateList.Count)
{
    $texts = @()
    $textsLength = $translateList[$index].Length
    
    while ( $index -lt $translateList.Count -and 
            $texts.Count -lt $maxTextsCnt -and 
            $textsLength  -le $maxTextsLength)
    {
        $texts += $translateList[$index]
        $index++
        $textsLength += $translateList[$index].Length
    }
    write-host "Translating $($texts.Count) texts of total length $($textsLength - $translateList[$index].Length), at index: $($index - $texts.Count)"

    $body = ConvertTo-Json ($texts | Select @{Name="Text"; Expression = { $_.Replace('“','"').Replace('”', '"').Replace("Norwegian (Bokmål)","Norwegian") }} )
    $translate = Invoke-RestMethod "https://api.cognitive.microsofttranslator.com/translate?api-version=3.0&from=en&to=cs" -Method Post -body $body -Headers $header

    for($i = 0; $i -lt $texts.Count; $i++)
    {
        $cacheItem = "" | Select OriginalEnglish, Translation, Locations
        $cacheItem.OriginalEnglish = $texts[$i]
        $cacheItem.Translation = $translate[$i].translations[0].text
        $cacheItem.Locations = ""
        $cache += $cacheItem
    }

    $cache | Export-Csv $cachePath -NoTypeInformation -Encoding UTF8
}

#clean locations- the code might have changed
$cache | foreach {$_.Locations = ""}

#create translations directories and apply translations from the cache
foreach($enDir in $enDirs)
{
    $czDirPath = $enDir.Parent.FullName + "\cs-cz"
    write-host "Initializing localized content at $czDirPath)"

    if (Test-Path $czDirPath)
    {
        Remove-Item $czDirPath -Recurse
    }
    Copy-Item $enDir.FullName $czDirPath -Recurse

    $metadata = Get-Content "$czDirPath\metadata.json" -Encoding UTF8 | Out-String | ConvertFrom-Json
    $assets = Get-Content "$czDirPath\assets.json" -Encoding UTF8 | Out-String | ConvertFrom-Json
    $playlists = Get-Content "$czDirPath\playlists.json" -Encoding UTF8 | Out-String | ConvertFrom-Json

    write-host "Applying translations on $czDirPath\playlists.json ($($playlists.Count) playlists)"
    foreach($playList in $playlists)
    {
        $playList.Title = GetCachedTranslation $cache $playList.Title "$czDirPath\playlists.json;$($playlist.Id);Title" $BaseDir
        $playList.Description = GetCachedTranslation $cache $playList.Description "$czDirPath\playlists.json;$($playlist.Id);Description" $BaseDir
    }
    
    $playlists | ConvertTo-Json | Set-Content "$czDirPath\playlists.json" -Encoding UTF8

    write-host "Applying translations on $czDirPath\assets.json ($($assets.Count) assets)"
    foreach($asset in $assets)
    {
        $asset.Title = GetCachedTranslation $cache $asset.Title "$czDirPath\assets.json;$($asset.Id);Title" $BaseDir
        $asset.Description = GetCachedTranslation $cache $asset.Description "$czDirPath\assets.json;$($asset.Id);Description" $BaseDir 
        $asset.Url = $asset.Url.Replace("en-us","cs-cz")
    }

    $assets | ConvertTo-Json | Set-Content "$czDirPath\assets.json" -Encoding UTF8

    write-host "Applying translations on $czDirPath\metadata.json"
    foreach($technology in $metadata.Technologies)
    {
        $technology.Name = GetCachedTranslation $cache $technology.Name "$czDirPath\metadata.json;Technology;$($technology.Id)" $BaseDir

        foreach($subject in $technology.Subjects)
        {
            $subject.Name = GetCachedTranslation $cache $subject.Name "$czDirPath\metadata.json;TechnologySubject;$($subject.Id)" $BaseDir
        }
    }

    foreach($category in $metadata.Categories)
    {
        $category.Name = GetCachedTranslation $cache $category.Name "$czDirPath\metadata.json;Category;$($category.Id)" $BaseDir

        foreach($subcategory in $category.Subcategories)
        {
            $subcategory.Name = GetCachedTranslation $cache $subcategory.Name "$czDirPath\metadata.json;Subcategory;$($subcategory.Id)" $BaseDir
        }
    }

    foreach($audience in $metadata.Audiences)
    {
        $audience.Name = GetCachedTranslation $cache $audience.Name "$czDirPath\metadata.json;Audience;$($audience.Id)" $BaseDir
    }

    foreach($level in $metadata.Levels)
    {
        $level.Name = GetCachedTranslation $cache $level.Name "$czDirPath\metadata.json;Level;$($level.Id)" $BaseDir
    }
              
    foreach($tag in $metadata.StatusTag)
    {
        $tag.Name = GetCachedTranslation $cache $tag.Name "$czDirPath\metadata.json;StatusTag;$($tag.Id)" $BaseDir
    }  
    

    $metadata | ConvertTo-Json -Depth 8 | Set-Content "$czDirPath\metadata.json" -Encoding UTF8
}

#apply translations on locals
$czSrcLocalsPath = $enSrcLocalsPath.Replace("1033", "1029")
write-host "Applying translations on $czSrcLocalsPath ($($locals.Count) locals)"
foreach($loc in $locals)
{
    $loc.Description = GetCachedTranslation $cache $loc.Description "$czSrcLocalsPath;$($loc.localeId)" $BaseDir
}

$locals | ConvertTo-Json | Set-Content $czSrcLocalsPath -Encoding UTF8

#apply translations on strings
$czSrcStringsPath = $enSrcStringsPath.Replace("en-us", "cs-cz")
write-host "Applying translations on web part strings $czSrcStringsPath ($($enStrings.Count) lines)"
if (Test-Path $czSrcStringsPath)
{
    Remove-Item $czSrcStringsPath
}
foreach($line in $enStrings)
{
    if ($line -match "(.+): `"(.+)`"")
    {
        $translation = (GetCachedTranslation $cache $matches[2] "$czSrcStringsPath;$($matches[1].Trim())" $BaseDir) 

        #specific fixes
        $translation = $translation -replace '%(\d+) %', '%$1%'
        $translation = $translation.Replace('"', "'")

        $line = $line.Replace('"' + $matches[2] + '"','"' + $translation + '"')
    }
    $line >> $czSrcStringsPath
}

#save cache locations
$cache | Export-Csv $cachePath -NoTypeInformation -Encoding UTF8


